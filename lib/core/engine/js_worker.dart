import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_js/javascriptcore/jscore_runtime.dart';
import 'package:flutter_js/javascript_runtime.dart';
import 'package:flutter_js/quickjs/quickjs_runtime2.dart';
import 'package:sync_http/sync_http.dart';

import 'js_module_source.dart';

/// One runtime per isolate also isolates JavaScriptCore's static callback slot.
/// No Flutter platform channels or asset loads occur inside this worker.
void runJsWorker(Map<String, dynamic> start) async {
  final output = start['output'] as SendPort;
  final input = ReceivePort();
  JavascriptRuntime? runtime;
  try {
    runtime = Platform.isIOS || Platform.isMacOS
        ? JavascriptCoreRuntime()
        : QuickJsRuntime2(stackSize: 2 * 1024 * 1024);
    final js = runtime;
    String evaluate(String code) {
      final result = js.evaluate(code);
      if (result.isError) throw StateError(result.stringResult);
      return result.stringResult;
    }

    js.onMessage('req', (dynamic args) {
      // Only loopback IPC is synchronous. HTTPS/redirects and response bounds
      // live in the asynchronous host, so the Flutter UI never blocks.
      // Never throw across the JSC FFI callback: JS unwraps this envelope.
      try {
        final request = SyncHttpClient.postUrl(Uri.parse(start['requestUrl']));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(args));
        final response = request.close();
        if (response.statusCode != 200) {
          return jsonEncode({'error': 'JS HTTP bridge: ${response.body}'});
        }
        return response.body ?? jsonEncode({'error': 'Empty JS HTTP response'});
      } catch (error) {
        return jsonEncode({'error': error.toString()});
      }
    });
    final local = <String, String>{};
    js.onMessage('local', (dynamic args) {
      final key = jsonEncode([args[1], args[2]]);
      switch (args[0]) {
        case 'get':
          return local[key] ?? args[3];
        case 'set':
          local[key] = '${args[3]}';
          return true;
        case 'delete':
          local.remove(key);
          return true;
      }
      return null;
    });
    js.onMessage('join', (dynamic args) {
      try {
        return Uri.parse('${args[0]}').resolve('${args[1]}').toString();
      } on FormatException {
        return '${args[1]}';
      }
    });
    js.onMessage('proxy', (_) => start['proxyUrl']);
    evaluate(start['host'] as String);
    evaluate('${start['bundle']}\n;null;');
    final source = prepareSingleFileJs(start['source'] as String);
    evaluate('''$source
;globalThis.__ruleMode = typeof rule !== 'undefined';
globalThis.__spider = typeof __JS_SPIDER__ !== 'undefined' ? __JS_SPIDER__ :
  typeof __jsEvalReturn === 'function' ? __jsEvalReturn() :
  typeof __lgDefault !== 'undefined' ? (typeof __lgDefault === 'function' ? __lgDefault() : __lgDefault) :
  __ruleMode ? __drpyGlobal.default : typeof module !== 'undefined' ? module.exports : null;
if (!__spider) throw Error('No drpy rule or spider export');
null;
''');
    final ext = jsonEncode(start['ext'] ?? '');
    await _evaluateCall(js, '''typeof __spider.init === 'function'
      ? __spider.init(__ruleMode ? rule : $ext) : null''');
    output.send({'ready': input.sendPort});
    // Sequential calls preserve source state and prevent overlapping JSC evals.
    await for (final dynamic message in input) {
      final id = message['id'];
      try {
        if (message['method'] == '__close') break;
        final method = message['method'] as String;
        final args = jsonEncode(message['args']);
        final result = await _evaluateCall(js, '''(() => {
          const s=__spider, name=${jsonEncode(method)};
          const aliases={home:'homeContent',category:'categoryContent',search:'searchContent',detail:'detailContent',play:'playerContent',homeVod:'homeVideoContent'};
          const fn=s[name] || s[aliases[name]];
          if (!fn && name==='homeVod') return {};
          if (!fn) throw Error('Missing spider method: '+name);
          let a=$args;
          if(name==='detail' && !s.detail) a=[a];
          return fn.apply(s,a);
        })()''');
        output.send({'id': id, 'result': result});
      } catch (error) {
        output.send({'id': id, 'error': error.toString()});
      }
    }
  } catch (error) {
    output.send({'error': error.toString()});
  } finally {
    runtime?.dispose();
    input.close();
    output.send({'closed': true});
  }
}

/// Resolve promises explicitly on both engines, and return only JSON strings.
/// This avoids the upstream handlePromise implementation's leaked timers.
Future<String> _evaluateCall(JavascriptRuntime js, String expression) async {
  final result = js.evaluate('''globalThis.__lgDone=false;
    globalThis.__lgValue=null; globalThis.__lgError=null;
    Promise.resolve().then(()=>($expression)).then(value=>{
      __lgValue=typeof value==='string'?value:JSON.stringify(value == null ? {} : value);
      __lgDone=true;
    },error=>{__lgError=String(error && error.stack || error);__lgDone=true;});
    null;''');
  if (result.isError) throw StateError(result.stringResult);
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (true) {
    js.executePendingJob();
    if (js.evaluate('__lgDone').stringResult == 'true') break;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('JS operation timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  final error = js.evaluate('__lgError').stringResult;
  if (error != 'null') throw StateError(error);
  return js.evaluate('__lgValue').stringResult;
}
