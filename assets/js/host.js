/* SPDX-License-Identifier: GPL-3.0-or-later */
// All native callbacks are synchronous inside a dedicated JS worker. HTTP is
// relayed to the UI isolate's asynchronous TLS client, never performed on UI.
const __host = (name, args) => sendMessage(name, JSON.stringify(args));
globalThis.console = {log(){}, warn(){}, error(){}, debug(){}};
globalThis.print = globalThis.log = console.log;
globalThis.req = (url, options={}) => JSON.parse(__host('req', [String(url), options || {}]));
globalThis.request = (url, options={}) => req(url, options).content;
globalThis.http = globalThis.req;
globalThis.local = {
  get:(scope,key,def='')=>__host('local',['get',scope,key,def]),
  set:(scope,key,value)=>__host('local',['set',scope,key,String(value)]),
  delete:(scope,key)=>__host('local',['delete',scope,key]),
};
globalThis.joinUrl = (base, child) => __host('join', [String(base),String(child)]);
globalThis.getProxy = () => __host('proxy', []);
globalThis.js2Proxy = (dynamic,type,key,url,headers={},param='') => getProxy()+param+'&from=catvod&siteType='+type+'&siteKey='+encodeURIComponent(key)+'&header='+encodeURIComponent(JSON.stringify(headers))+'&url='+encodeURIComponent(url);
function __select(html, rule) {
  const $ = __lgCheerio.load(String(html));
  let nodes = $.root();
  for (const part of String(rule).split('&&').filter(v=>v.trim())) {
    const pieces = part.trim().split('--');
    nodes = nodes.find(pieces.shift().trim());
    if (pieces.length) {
      nodes = nodes.clone();
      for (const excluded of pieces) nodes.find(excluded.trim()).remove();
    }
  }
  return { $, nodes };
}
globalThis.pdfa = (html, rule) => {
  const { $, nodes } = __select(html, rule);
  return nodes.toArray().map(node=>$.html(node));
};
globalThis.pdfh = (html, rule) => {
  const parts = String(rule).split('&&');
  const attr = parts.length > 1 ? parts.pop().trim() : 'Text';
  const { $, nodes } = __select(html, parts.join('&&'));
  const node = nodes.first();
  if (!node.length) return '';
  switch (attr.toLowerCase()) {
    case 'text': return node.text().replace(/\s+/g,' ').trim();
    case 'html': return node.html() || '';
    case 'outerhtml': return $.html(node);
    default: return node.attr(attr) || '';
  }
};
globalThis.pd = (html, rule, base='') => {
  const value = pdfh(html,rule);
  return base && value && !/^(javascript|data):/i.test(value) ? joinUrl(base,value) : value;
};
globalThis.md5 = text => CryptoJS.MD5(String(text)).toString();
globalThis.md5X = globalThis.md5;
globalThis.base64Encode = text => CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse(text));
globalThis.base64Decode = text => CryptoJS.enc.Base64.parse(text).toString(CryptoJS.enc.Utf8);
