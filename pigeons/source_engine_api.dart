import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/core/engine/source_engine_api.g.dart',
  kotlinOut: 'android/source_engine/src/main/kotlin/cn/liuguang/engine/SourceEngineApi.g.kt',
  kotlinOptions: KotlinOptions(package: 'cn.liuguang.engine'),
  dartPackageName: 'tvbox',
))
@HostApi()
abstract class SourceEngineApi {
  @async
  String openSession(String configJson, String siteJson);
  @async
  String home(String sessionId, bool filter);
  @async
  String category(String sessionId, String tid, int page, String filtersJson);
  @async
  String search(String sessionId, String keyword, int page);
  @async
  String detail(String sessionId, String id);
  @async
  String play(String sessionId, String flag, String id);
  @async
  String resolve(String sessionId, String resultJson, String parserJson);
  @async
  String fetchLocal(String sessionId, String url);
  @async
  void cancel(String sessionId);
  @async
  void closeSession(String sessionId);
  @async
  String capabilities();
}
