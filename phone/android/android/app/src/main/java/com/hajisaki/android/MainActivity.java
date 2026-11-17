package com.hajisaki.android;

import com.getcapacitor.BridgeActivity;
import com.getcapacitor.BridgeWebChromeClient;

public class MainActivity extends BridgeActivity {
    @Override public void onCreate(android.os.Bundle savedInstanceState) {
        registerPlugin(HajiConnectionPlugin.class);
        super.onCreate(savedInstanceState);
        getBridge().getWebView().getSettings().setGeolocationEnabled(false);
        android.webkit.CookieManager.getInstance().setAcceptThirdPartyCookies(getBridge().getWebView(),true);
        getBridge().getWebView().setWebChromeClient(new BridgeWebChromeClient(getBridge()) {
            @Override public boolean onConsoleMessage(android.webkit.ConsoleMessage message) {
                if(message.messageLevel()==android.webkit.ConsoleMessage.MessageLevel.ERROR)
                    android.util.Log.e("HajiWeb",message.message()+" at "+message.sourceId()+":"+message.lineNumber());
                return super.onConsoleMessage(message);
            }
        });
    }
}
