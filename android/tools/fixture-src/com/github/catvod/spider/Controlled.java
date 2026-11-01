package com.github.catvod.spider;
import android.content.Context;
import com.github.catvod.crawler.Spider;
import java.util.*;
import java.io.ByteArrayInputStream;
public final class Controlled extends Spider {
    private String ext;
    @Override public void init(Context context,String extend) { ext=extend; }
    @Override public String homeContent(boolean filter) { return "{\"class\":[{\"type_id\":\"1\",\"type_name\":\"Controlled\"}],\"ext\":\""+ext+"\"}"; }
    @Override public String homeVideoContent() { return "{\"list\":[{\"vod_id\":\"one\",\"vod_name\":\"Fixture\"}]}"; }
    @Override public String categoryContent(String tid,String pg,boolean filter,HashMap<String,String> extend) { return "{\"page\":"+pg+",\"list\":[{\"vod_id\":\"one\"}]}"; }
    @Override public String detailContent(List<String> ids) { return "{\"list\":[{\"vod_id\":\"one\",\"vod_play_from\":\"fixture\",\"vod_play_url\":\"One$https://example.invalid/video.m3u8\"}]}"; }
    @Override public String searchContent(String keyword,boolean quick,String pg) { return "{\"page\":"+pg+",\"list\":[{\"vod_id\":\"one\"}]}"; }
    @Override public String playerContent(String flag,String id,List<String> vip) { return "{\"parse\":0,\"url\":\"https://example.invalid/video.m3u8\",\"header\":{\"Referer\":\"https://example.invalid/\"}}"; }
    @Override public Object[] proxyLocal(Map<String,String> params) { return new Object[]{200,"text/plain",new ByteArrayInputStream("controlled-proxy".getBytes(java.nio.charset.StandardCharsets.UTF_8))}; }
}
