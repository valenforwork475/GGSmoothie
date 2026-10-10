package com.ggpos.sunmi;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.MultiFormatWriter;
import com.google.zxing.common.BitMatrix;
import android.os.Bundle;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import com.sunmi.peripheral.printer.InnerPrinterCallback;
import com.sunmi.peripheral.printer.InnerPrinterException;
import com.sunmi.peripheral.printer.InnerPrinterManager;
import com.sunmi.peripheral.printer.InnerResultCallback;
import com.sunmi.peripheral.printer.SunmiPrinterService;

public class MainActivity extends Activity {
    private static final String POS_URL="https://sky-pos.vercel.app/POS-1c-standalone.html?source=android&print=v2";
    private WebView webView;
    private final ExecutorService executor=Executors.newSingleThreadExecutor();
    private Bitmap receiptLogo;
    private volatile SunmiPrinterService sunmiPrinterService;
    private final InnerPrinterCallback sunmiPrinterCallback=new InnerPrinterCallback(){
        @Override protected void onConnected(SunmiPrinterService service){sunmiPrinterService=service;}
        @Override protected void onDisconnected(){sunmiPrinterService=null;}
    };

    @Override public void onCreate(Bundle b){super.onCreate(b);startPrintService();bindSunmiPrinterService();webView=new WebView(this);setContentView(webView);WebSettings s=webView.getSettings();s.setJavaScriptEnabled(true);s.setDomStorageEnabled(true);s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);webView.setWebViewClient(new WebViewClient());webView.setWebChromeClient(new WebChromeClient());webView.addJavascriptInterface(new PrinterBridge(),"GGPrinter");webView.loadUrl(POS_URL);}
    @Override protected void onDestroy(){try{InnerPrinterManager.getInstance().unBindService(this,sunmiPrinterCallback);}catch(Exception ignored){}executor.shutdownNow();super.onDestroy();}
    private void bindSunmiPrinterService(){try{InnerPrinterManager.getInstance().bindService(this,sunmiPrinterCallback);}catch(InnerPrinterException ignored){sunmiPrinterService=null;}}
    @Override public void onBackPressed(){webView.evaluateJavascript("window.ggHandleBack?window.ggHandleBack():false",value->{if(!"true".equals(value)){if(webView.canGoBack())webView.goBack();else MainActivity.super.onBackPressed();}});}

    private String defaultHost(String route){if("kitchen".equals(route))return "10.1.7.205";if("main".equals(route))return "10.1.7.102";return "10.1.7.103";}
    private String host(String route){return getSharedPreferences("printers",0).getString(route+"_host",defaultHost(route));}
    private int port(String route){return getSharedPreferences("printers",0).getInt(route+"_port",9100);}
    private void startPrintService(){Intent i=new Intent(this,KitchenPrintService.class);if(Build.VERSION.SDK_INT>=Build.VERSION_CODES.O)startForegroundService(i);else startService(i);}

    public class PrinterBridge {
        @JavascriptInterface public String getConfig(){try{return new JSONObject().put("host",host("receipt")).put("port",port("receipt")).put("paperMm",80).put("native",true).put("backgroundPrint",true).put("printVersion",9).put("appVersion","1.4.9").put("sunmiDrawer",sunmiPrinterService!=null).toString();}catch(Exception e){return "{}";}}
        @JavascriptInterface public boolean backgroundPrintEnabled(){return true;}
        @JavascriptInterface public void syncBackgroundSession(String url,String key,String token){getSharedPreferences("background_print",0).edit().putString("url",url==null?"":url.trim()).putString("key",key==null?"":key.trim()).putString("token",token==null?"":token.trim()).apply();startPrintService();}
        @JavascriptInterface public String getPrinters(){try{JSONObject o=new JSONObject();for(String r:new String[]{"main","kitchen","receipt"})o.put(r,new JSONObject().put("host",host(r)).put("port",port(r)));return o.put("native",true).put("printVersion",2).toString();}catch(Exception e){return "{}";}}
        @JavascriptInterface public void saveConfig(String h,int p){savePrinter("receipt",h,p);}
        @JavascriptInterface public void savePrinter(String route,String h,int p){if(!route.equals("main")&&!route.equals("kitchen")&&!route.equals("receipt"))return;getSharedPreferences("printers",0).edit().putString(route+"_host",h==null?defaultHost(route):h.trim()).putInt(route+"_port",p>0?p:9100).apply();}
        @JavascriptInterface public void testPrint(String id){testPrinter("receipt",id);}
        @JavascriptInterface public void testPrinter(String route,String id){executor.execute(()->{try{JSONObject p=new JSONObject().put("header","SkyPOS\nทดสอบเครื่องพิมพ์").put("table",route).put("note","หากอ่านข้อความนี้ได้ แสดงว่าเชื่อมต่อสำเร็จ");send(route,render(route,p));callback(id,true,"พิมพ์ทดสอบสำเร็จ");}catch(Exception e){callback(id,false,e.getMessage());}});}
        @JavascriptInterface public void printOrder(String route,String payload,String id){executor.execute(()->{try{send(route,render(route,new JSONObject(payload)));callback(id,true,"พิมพ์สำเร็จ");}catch(Exception e){callback(id,false,e.getMessage());}});}
        @JavascriptInterface public void openCashDrawer(String id){executor.execute(()->openCashDrawerAll(id));}
    }

    // สั่งเปิดลิ้นชักทุกช่องทาง: ทั้งทางเครื่องพิมพ์ใบเสร็จ (RJ11 Pin 2 และ Pin 5) และพอร์ตลิ้นชักของเครื่อง SUNMI
    private void openCashDrawerAll(String id){
        boolean lanOk=false;
        try{sendCashDrawerPulse();lanOk=true;}catch(Exception ignored){}
        boolean sunmiOk=false;
        try{sunmiOk=openSunmiCashDrawerSync();}catch(Exception ignored){}
        if(lanOk||sunmiOk){
            callback(id,true,"ส่งคำสั่งเปิดลิ้นชักแล้ว (ตรวจเครื่องพิมพ์ใบเสร็จ/เครื่อง SUNMI)");
        }else{
            callback(id,false,"เปิดลิ้นชักไม่ได้ กรุณาตรวจสายลิ้นชัก (เสียบช่อง DK หลังเครื่องพิมพ์ใบเสร็จ หรือช่องลิ้นชัก SUNMI)");
        }
    }

    private boolean openSunmiCashDrawerSync(){
        SunmiPrinterService service=sunmiPrinterService;
        if(service==null){bindSunmiPrinterService();return false;}
        try{
            service.openDrawer(new InnerResultCallback(){
                @Override public void onRunResult(boolean success){}
                @Override public void onReturnString(String value){}
                @Override public void onRaiseException(int code,String message){}
                @Override public void onPrintResult(int code,String message){}
            });
            service.sendRAWData(new byte[]{0x10,0x14,0x01,0x00,0x05},null);
            service.sendRAWData(new byte[]{0x1b,0x70,0x00,0x19,(byte)0xfa},null);
            service.sendRAWData(new byte[]{0x1b,0x70,0x01,0x19,(byte)0xfa},null);
            return true;
        }catch(Exception e){return false;}
    }

    private void callback(String id,boolean ok,String message){runOnUiThread(()->webView.evaluateJavascript("window.dispatchEvent(new CustomEvent('gg-printer-result',{detail:"+JSONObject.quote("{\"id\":"+JSONObject.quote(id)+",\"ok\":"+ok+",\"message\":"+JSONObject.quote(message==null?"":message)+"}")+"}));",null));}

    private static class Line {String text;float size;boolean bold;Paint.Align align;Line(String t,float s,boolean b,Paint.Align a){text=t;size=s;bold=b;align=a;}}
    private List<String> wrap(String text,Paint paint,float max){List<String> out=new ArrayList<>();for(String paragraph:(text==null?"":text).replace("\r","").split("\n",-1)){if(paragraph.isEmpty()){out.add("");continue;}String rest=paragraph;while(!rest.isEmpty()){int end=paint.breakText(rest,true,max,null);if(end<=0)end=1;if(end<rest.length()){int space=rest.lastIndexOf(' ',end-1);if(space>end/2)end=space+1;}out.add(rest.substring(0,end).trim());rest=rest.substring(end).trim();}}return out;}
    private void addWrapped(List<Line> lines,String text,float size,boolean bold,Paint.Align align,float width){Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);p.setTextSize(size);p.setFakeBoldText(bold);for(String s:wrap(text,p,width))lines.add(new Line(s,size,bold,align));}
    private Bitmap render(String route,JSONObject data)throws Exception{
        final int width=576;final float content=528;List<Line> lines=new ArrayList<>();
        String header=data.optString("header","");if(!header.isEmpty())addWrapped(lines,header,25,true,Paint.Align.CENTER,content);
        String title=data.optString("title","");if(!title.isEmpty())addWrapped(lines,title,36,true,Paint.Align.CENTER,content);
        String sellerTax=data.optString("sellerTax","");if(!sellerTax.isEmpty())addWrapped(lines,sellerTax,24,true,Paint.Align.CENTER,content);
        String customer=data.optString("customer","");if(!customer.isEmpty()){lines.add(new Line("────────────────────────",20,false,Paint.Align.CENTER));addWrapped(lines,customer,25,true,Paint.Align.LEFT,content);}
        String table=data.optString("table","");if(!table.isEmpty())addWrapped(lines,("kitchen".equals(route)?"ใบสั่งครัว · ":"")+table,34,true,Paint.Align.CENTER,content);
        String docNo=data.optString("docNo","");if(!docNo.isEmpty())addWrapped(lines,docNo,21,false,Paint.Align.CENTER,content);
        String guests=data.optString("guests","");if(!guests.isEmpty()&&!"0".equals(guests))addWrapped(lines,"ลูกค้า "+guests+" คน",22,false,Paint.Align.CENTER,content);
        String date=data.optString("date",new SimpleDateFormat("dd/MM/yyyy HH:mm",new Locale("th","TH")).format(new Date()));addWrapped(lines,date,22,false,Paint.Align.CENTER,content);
        lines.add(new Line("────────────────────────",20,false,Paint.Align.CENTER));
        JSONArray items=data.optJSONArray("items");if(items!=null)for(int i=0;i<items.length();i++){JSONObject item=items.getJSONObject(i);int qty=item.optInt("qty",1);String name=item.optString("name","");addWrapped(lines,qty+" × "+name,34,true,Paint.Align.LEFT,content);String detail=item.optString("detail","");if(!detail.isEmpty())for(String option:detail.split(" · "))addWrapped(lines,"• "+option,36,true,Paint.Align.LEFT,content-28);if(item.has("price"))addWrapped(lines,"฿"+String.format(Locale.US,"%.2f",item.optDouble("price",0)*qty),28,true,Paint.Align.RIGHT,content);lines.add(new Line("────────────────────────",18,false,Paint.Align.CENTER));}
        String note=data.optString("note","");if(!note.isEmpty())addWrapped(lines,note,27,true,Paint.Align.LEFT,content);
        String barcode=data.optString("barcode","");String barcodeLabel=data.optString("barcodeLabel","");int barcodeSpace=barcode.isEmpty()?0:180;
        int logoSpace="receipt".equals(route)?320:0,height=44+logoSpace;for(Line l:lines)height+=(int)(l.size*1.42f);height+=barcodeSpace+48;height=Math.max(height,280);
        Bitmap bmp=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);Canvas c=new Canvas(bmp);c.drawColor(Color.WHITE);Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);p.setColor(Color.BLACK);float y=34;if(logoSpace>0){Bitmap logo=getReceiptLogo();if(logo!=null)c.drawBitmap(logo,null,new Rect(148,10,428,290),p);y=330;}
        for(Line l:lines){p.setTextSize(l.size);p.setFakeBoldText(l.bold);p.setTextAlign(l.align);float x=l.align==Paint.Align.CENTER?width/2f:l.align==Paint.Align.RIGHT?width-24:24;c.drawText(l.text,x,y,p);y+=l.size*1.42f;}
        if(!barcode.isEmpty()){Bitmap bars=code128(barcode,500,105);c.drawBitmap(bars,null,new Rect(38,(int)y,538,(int)y+105),p);bars.recycle();y+=125;p.setTextAlign(Paint.Align.CENTER);p.setTextSize(21);p.setFakeBoldText(true);c.drawText(barcodeLabel,width/2f,y,p);}
        return bmp;
    }
    private Bitmap code128(String value,int width,int height)throws Exception{BitMatrix matrix=new MultiFormatWriter().encode(value,BarcodeFormat.CODE_128,width,height);Bitmap bitmap=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);for(int y=0;y<height;y++)for(int x=0;x<width;x++)bitmap.setPixel(x,y,matrix.get(x,y)?Color.BLACK:Color.WHITE);return bitmap;}
    private void send(String route,Bitmap bitmap)throws Exception{try(Socket socket=new Socket()){socket.connect(new InetSocketAddress(host(route),port(route)),5000);socket.setSoTimeout(5000);OutputStream out=socket.getOutputStream();out.write(new byte[]{0x1b,0x40});out.write(raster(bitmap));out.write(new byte[]{0x0a,0x0a,0x0a,0x1d,0x56,0x00});out.flush();}}
    private void sendCashDrawerPulse()throws Exception{try(Socket socket=new Socket()){socket.connect(new InetSocketAddress(host("receipt"),port("receipt")),5000);socket.setSoTimeout(5000);OutputStream out=socket.getOutputStream();out.write(new byte[]{0x1b,0x40,0x1b,0x70,0x00,0x19,(byte)0xFA});out.flush();}}
    private synchronized Bitmap getReceiptLogo(){if(receiptLogo!=null&&!receiptLogo.isRecycled())return receiptLogo;Bitmap source=BitmapFactory.decodeResource(getResources(),R.drawable.receipt_logo);if(source==null)return null;Bitmap scaled=Bitmap.createScaledBitmap(source,280,280,true);source.recycle();receiptLogo=outlineLogo(scaled);scaled.recycle();return receiptLogo;}
    private Bitmap outlineLogo(Bitmap source){Bitmap out=Bitmap.createBitmap(source.getWidth(),source.getHeight(),Bitmap.Config.ARGB_8888);for(int y=0;y<source.getHeight();y++)for(int x=0;x<source.getWidth();x++){int c=source.getPixel(x,y),r=Color.red(c),g=Color.green(c),b=Color.blue(c),max=Math.max(r,Math.max(g,b)),min=Math.min(r,Math.min(g,b)),gray=(r+g+b)/3;out.setPixel(x,y,(gray<105&&max-min<45)?Color.BLACK:Color.WHITE);}return out;}
    private byte[] raster(Bitmap bmp)throws Exception{int w=(bmp.getWidth()+7)/8,h=bmp.getHeight();ByteArrayOutputStream out=new ByteArrayOutputStream();out.write(new byte[]{0x1d,0x76,0x30,0x00,(byte)(w&255),(byte)((w>>8)&255),(byte)(h&255),(byte)((h>>8)&255)});for(int y=0;y<h;y++)for(int xb=0;xb<w;xb++){int b=0;for(int bit=0;bit<8;bit++){int x=xb*8+bit;if(x<bmp.getWidth()){int color=bmp.getPixel(x,y);int gray=(Color.red(color)+Color.green(color)+Color.blue(color))/3;if(gray<160)b|=1<<(7-bit);}}out.write(b);}return out.toByteArray();}
}
