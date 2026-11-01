/* SPDX-License-Identifier: GPL-3.0-or-later */
globalThis.console = {log:(...a)=>__log(...a),warn:(...a)=>__log(...a),error:(...a)=>__log(...a),debug:(...a)=>__log(...a)};
globalThis.print=console.log;
globalThis.log=console.log;
globalThis.req=(url,options={})=>JSON.parse(__req(String(url),JSON.stringify(options||{})));
globalThis.request=(url,options={})=>req(url,options).content;
globalThis.http=globalThis.req;
globalThis.local={get:(scope,key,def='')=>__local('get',scope,key,def),set:(scope,key,value)=>__local('set',scope,key,String(value)),delete:(scope,key)=>__local('delete',scope,key)};
globalThis.pdfh=(html,rule)=>__pdfh(String(html),String(rule),'');
globalThis.pdfa=(html,rule)=>JSON.parse(__pdfa(String(html),String(rule)));
globalThis.pd=(html,rule,base)=>__pdfh(String(html),String(rule),String(base||''));
globalThis.joinUrl=(base,child)=>__joinUrl(String(base),String(child));
globalThis.getProxy=()=>__proxy();
globalThis.js2Proxy=(dynamic,type,key,url,headers={},param='')=>getProxy()+param+'&from=catvod&siteType='+type+'&siteKey='+encodeURIComponent(key)+'&header='+encodeURIComponent(JSON.stringify(headers))+'&url='+encodeURIComponent(url);
globalThis.md5=(text)=>CryptoJS.MD5(String(text)).toString();
globalThis.md5X=globalThis.md5;
globalThis.base64Encode=(text)=>CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse(text));
globalThis.base64Decode=(text)=>CryptoJS.enc.Base64.parse(text).toString(CryptoJS.enc.Utf8);
