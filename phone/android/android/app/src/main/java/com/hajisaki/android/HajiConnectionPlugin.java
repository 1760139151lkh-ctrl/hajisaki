package com.hajisaki.android;

import android.provider.Settings;
import android.app.Activity;
import android.content.Intent;
import androidx.activity.result.ActivityResult;
import com.getcapacitor.annotation.ActivityCallback;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

@CapacitorPlugin(name="HajiConnection")
public class HajiConnectionPlugin extends Plugin {
    private JSObject connection() throws Exception {
        String raw=getContext().getSharedPreferences("hajisaki",0).getString("connection","");
        if(raw.isEmpty())return null;
        byte[] bytes=Base64.decode(raw,Base64.NO_WRAP),iv=new byte[12];System.arraycopy(bytes,0,iv,0,12);
        Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,iv));
        return new JSObject(new String(cipher.doFinal(bytes,12,bytes.length-12),StandardCharsets.UTF_8));
    }
    private SecretKey key() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore"); store.load(null);
        if(!store.containsAlias("hajisaki-connection")) {
            KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder("hajisaki-connection",KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            generator.generateKey();
        }
        return ((KeyStore.SecretKeyEntry)store.getEntry("hajisaki-connection",null)).getSecretKey();
    }
    @PluginMethod public void load(PluginCall call) {
        try {
            JSObject result=new JSObject();
            JSObject saved=connection();if(saved!=null)result.put("connection",saved);
            try(java.io.InputStream input=getContext().getAssets().open("mobile-bootstrap.json")) {
                java.io.ByteArrayOutputStream buffer=new java.io.ByteArrayOutputStream(); byte[] block=new byte[4096]; int count;
                while((count=input.read(block))!=-1)buffer.write(block,0,count);
                result.put("bootstrap",new JSObject(new String(buffer.toByteArray(),StandardCharsets.UTF_8)));
            }
            result.put("instance",Settings.Secure.getString(getContext().getContentResolver(),Settings.Secure.ANDROID_ID));
            call.resolve(result);
        } catch(Exception error) {call.reject("琴房的钥匙暂时没有取出。",error);}
    }
    @PluginMethod public void save(PluginCall call) {
        try {
            JSObject data=call.getObject("connection"); if(data==null)throw new IllegalArgumentException();
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE,key());
            byte[] encrypted=cipher.doFinal(data.toString().getBytes(StandardCharsets.UTF_8)),iv=cipher.getIV(),bytes=new byte[iv.length+encrypted.length];
            System.arraycopy(iv,0,bytes,0,iv.length); System.arraycopy(encrypted,0,bytes,iv.length,encrypted.length);
            if(!getContext().getSharedPreferences("hajisaki",0).edit().putString("connection",Base64.encodeToString(bytes,Base64.NO_WRAP)).commit())throw new java.io.IOException();
            call.resolve();
        } catch(Exception error) {call.reject("钥匙暂时没有收好，请保留这一页。",error);}
    }
    @PluginMethod public void clear(PluginCall call) {
        if(getContext().getSharedPreferences("hajisaki",0).edit().remove("connection").commit())call.resolve();
        else call.reject("钥匙暂时没有收好。");
    }
    @PluginMethod public void appearance(PluginCall call) {
        boolean day="day".equals(call.getString("theme"));
        getActivity().runOnUiThread(()->{
            android.view.Window window=getActivity().getWindow();
            int color=android.graphics.Color.parseColor(day?"#FBF4F1":"#17131F");
            window.setStatusBarColor(color);window.setNavigationBarColor(color);
            window.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(color));
            window.getDecorView().setBackgroundColor(color);
            androidx.core.view.WindowInsetsControllerCompat controller=new androidx.core.view.WindowInsetsControllerCompat(window,window.getDecorView());
            controller.setAppearanceLightStatusBars(day);controller.setAppearanceLightNavigationBars(day);call.resolve();
        });
    }
    @PluginMethod public void saveFile(PluginCall call) {
        if(android.os.Build.VERSION.SDK_INT>=29) {
            try {
                android.content.ContentValues values=new android.content.ContentValues();
                values.put(android.provider.MediaStore.Downloads.DISPLAY_NAME,call.getString("name","琴房原件"));
                values.put(android.provider.MediaStore.Downloads.MIME_TYPE,call.getString("mime","application/octet-stream"));
                values.put(android.provider.MediaStore.Downloads.RELATIVE_PATH,android.os.Environment.DIRECTORY_DOWNLOADS);
                values.put(android.provider.MediaStore.Downloads.IS_PENDING,1);
                android.net.Uri uri=getContext().getContentResolver().insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,values);
                if(uri==null)throw new java.io.IOException();
                writeFile(call,uri,true);return;
            } catch(Exception error){call.reject("下载文件夹暂时没有打开，请重试。",error);return;}
        }
        Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION|Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        intent.setType(call.getString("mime","application/octet-stream"));intent.putExtra(Intent.EXTRA_TITLE,call.getString("name","琴房原件"));
        startActivityForResult(call,intent,"fileChosen");
    }
    @ActivityCallback protected void fileChosen(PluginCall call,ActivityResult result) {
        if(call==null)return;
        if(result.getResultCode()!=Activity.RESULT_OK || result.getData()==null){call.resolve();return;}
        android.net.Uri uri=result.getData().getData();
        try {
            int flags=result.getData().getFlags() & (Intent.FLAG_GRANT_READ_URI_PERMISSION|Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            getContext().getContentResolver().takePersistableUriPermission(uri,flags);
        } catch(SecurityException error) {android.util.Log.w("HajiFile","Destination grant could not be persisted",error);}
        writeFile(call,uri,false);
    }
    private void writeFile(PluginCall call,android.net.Uri uri,boolean download) {
        new Thread(()->{
            java.net.HttpURLConnection remote=null;
            try(java.io.OutputStream output=getContext().getContentResolver().openOutputStream(uri,"w")) {
                if(output==null)throw new java.io.IOException();
                String path=call.getString("path");
                if(path!=null) {
                    if(!path.matches("/api/(export|artifacts/[A-Za-z0-9_-]+/content)"))throw new SecurityException();
                    JSObject saved=connection();if(saved==null)throw new SecurityException();
                    remote=(java.net.HttpURLConnection)new java.net.URL(saved.getString("origin")+path).openConnection();
                    remote.setInstanceFollowRedirects(false);remote.setConnectTimeout(20000);remote.setReadTimeout(90000);
                    remote.setRequestProperty("Authorization","Bearer "+saved.getString("token"));remote.setRequestProperty("X-Haji-Device",saved.getString("device"));
                    if(remote.getResponseCode()!=200)throw new java.io.IOException();
                    try(java.io.InputStream input=remote.getInputStream()){byte[] block=new byte[65536];int count;while((count=input.read(block))!=-1)output.write(block,0,count);}
                } else output.write(Base64.decode(call.getString("data",""),Base64.DEFAULT));
                output.flush();
                if(download && android.os.Build.VERSION.SDK_INT>=29){android.content.ContentValues values=new android.content.ContentValues();values.put(android.provider.MediaStore.Downloads.IS_PENDING,0);getContext().getContentResolver().update(uri,values,null,null);}
                call.resolve();getActivity().runOnUiThread(()->android.widget.Toast.makeText(getContext(),download?"已存入下载文件夹":"文件已保存",android.widget.Toast.LENGTH_LONG).show());
            } catch(Exception error){android.util.Log.e("HajiFile","File save failed",error);call.reject("原件还没有完整保存，请重试。",error);}
            finally{if(remote!=null)remote.disconnect();}
        },"hajisaki-file-save").start();
    }
}
