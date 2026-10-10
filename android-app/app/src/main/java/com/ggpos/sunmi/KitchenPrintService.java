package com.ggpos.sunmi;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Build;
import android.os.IBinder;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public class KitchenPrintService extends Service {
    private static final String CHANNEL="skypos_print_service";
    private static final int NOTIFICATION_ID=1300;
    private final ScheduledExecutorService worker=Executors.newSingleThreadScheduledExecutor();

    @Override public void onCreate(){super.onCreate();startForeground(NOTIFICATION_ID,notification());worker.scheduleWithFixedDelay(this::pollSafely,1,3, TimeUnit.SECONDS);}
    @Override public int onStartCommand(Intent intent,int flags,int startId){return START_STICKY;}
    @Override public void onDestroy(){worker.shutdownNow();super.onDestroy();}
    @Override public IBinder onBind(Intent intent){return null;}

    private Notification notification(){
        NotificationManager nm=(NotificationManager)getSystemService(NOTIFICATION_SERVICE);
        if(Build.VERSION.SDK_INT>=Build.VERSION_CODES.O)nm.createNotificationChannel(new NotificationChannel(CHANNEL,"SkyPOS Kitchen Print",NotificationManager.IMPORTANCE_LOW));
        Intent open=new Intent(this,MainActivity.class);PendingIntent pi=PendingIntent.getActivity(this,0,open,PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.stat_notify_sync_noanim).setContentTitle("SkyPOS พร้อมรับบิลจาก iPad").setContentText("บริการพิมพ์ครัวทำงานอยู่เบื้องหลัง").setOngoing(true).setContentIntent(pi).build();
    }

    private void pollSafely(){try{poll();}catch(Exception ignored){}}
    private void poll() throws Exception{
        SharedPreferences auth=getSharedPreferences("background_print",0);String base=auth.getString("url","");String key=auth.getString("key","");String token=auth.getString("token","");
        if(base.isEmpty()||key.isEmpty()||token.isEmpty())return;
        JSONArray rows=new JSONArray(post(base+"/rest/v1/rpc/get_pos_table_orders",key,token,"{}"));
        for(int i=0;i<rows.length();i++){JSONObject order=rows.getJSONObject(i);if(order.optBoolean("kitchen_pending",false)&&printOrder(order))post(base+"/rest/v1/rpc/mark_pos_table_kitchen_printed",key,token,new JSONObject().put("p_table_no",order.optString("table_no")).put("p_version",order.optInt("version")).toString());String requested=order.optString("bill_print_requested_at","");String printed=order.optString("bill_printed_at","");if(!requested.isEmpty()&&(printed.isEmpty()||requested.compareTo(printed)>0)&&printTableBill(order.optJSONObject("bill_print_payload")))post(base+"/rest/v1/rpc/mark_pos_table_bill_printed",key,token,new JSONObject().put("p_table_no",order.optString("table_no")).put("p_requested_at",requested).toString());}
    }

    private boolean printOrder(JSONObject order) throws Exception{
        JSONObject groups=new JSONObject().put("main",new JSONArray()).put("kitchen",new JSONArray());JSONArray cart=order.optJSONArray("cart");if(cart==null)return false;
        for(int i=0;i<cart.length();i++){
            JSONObject line=cart.getJSONObject(i);
            int printedQty = line.has("printedQty") ? line.optInt("printedQty", 0) : (line.optBoolean("kitchenPrinted", false) ? line.optInt("qty", 1) : 0);
            int newQty = line.optInt("qty", 1) - printedQty;
            if (newQty <= 0) continue;
            String route=line.optString("printerRoute",line.optString("printer_route","main"));
            if("none".equals(route)||"skip".equals(route)||"no_print".equals(route)) continue;
            if(!"kitchen".equals(route))route="main";
            groups.getJSONArray(route).put(new JSONObject().put("name",line.optString("name")).put("qty",newQty).put("detail",line.optString("modText",line.optString("desc",""))));
        }
        boolean printed=false;for(String route:new String[]{"main","kitchen"}){JSONArray items=groups.getJSONArray(route);for(int i=0;i<items.length();i++){JSONObject payload=new JSONObject().put("table",order.optString("table_no")).put("guests",order.optInt("guest_count",1)).put("items",new JSONArray().put(items.getJSONObject(i))).put("note",order.optString("note",""));send(route,render(route,payload));printed=true;}}return printed;
    }

    private boolean printTableBill(JSONObject payload)throws Exception{if(payload==null)return false;send("receipt",renderReceipt(payload));return true;}

    private String post(String endpoint,String key,String token,String body)throws Exception{HttpURLConnection c=(HttpURLConnection)new URL(endpoint).openConnection();c.setConnectTimeout(10000);c.setReadTimeout(15000);c.setRequestMethod("POST");c.setRequestProperty("apikey",key);c.setRequestProperty("Authorization","Bearer "+token);c.setRequestProperty("Content-Type","application/json");c.setDoOutput(true);try(OutputStream out=c.getOutputStream()){out.write(body.getBytes("UTF-8"));}int status=c.getResponseCode();InputStream stream=status>=200&&status<300?c.getInputStream():c.getErrorStream();StringBuilder text=new StringBuilder();if(stream!=null)try(BufferedReader r=new BufferedReader(new InputStreamReader(stream,"UTF-8"))){String line;while((line=r.readLine())!=null)text.append(line);}if(status<200||status>=300)throw new Exception("Supabase "+status+" "+text);return text.toString();}

    private static class Line{String text;float size;boolean bold;Paint.Align align;Line(String text,float size,boolean bold,Paint.Align align){this.text=text;this.size=size;this.bold=bold;this.align=align;}}
    private List<String> wrap(String text,Paint paint,float max){List<String> out=new ArrayList<>();for(String paragraph:(text==null?"":text).replace("\r","").split("\n",-1)){if(paragraph.isEmpty()){out.add("");continue;}String rest=paragraph;while(!rest.isEmpty()){int end=paint.breakText(rest,true,max,null);if(end<=0)end=1;if(end<rest.length()){int space=rest.lastIndexOf(' ',end-1);if(space>end/2)end=space+1;}out.add(rest.substring(0,end).trim());rest=rest.substring(end).trim();}}return out;}
    private void addWrapped(List<Line> lines,String text,float size,boolean bold,Paint.Align align,float width){Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);p.setTextSize(size);p.setFakeBoldText(bold);for(String value:wrap(text,p,width))lines.add(new Line(value,size,bold,align));}
    private Bitmap render(String route,JSONObject data)throws Exception{final int width=576;final float content=528;List<Line> lines=new ArrayList<>();addWrapped(lines,"ใบสั่งครัว · โต๊ะ "+data.optString("table","-"),36,true,Paint.Align.CENTER,content);int guests=data.optInt("guests",0);if(guests>0)addWrapped(lines,"ลูกค้า "+guests+" คน",24,true,Paint.Align.CENTER,content);addWrapped(lines,new SimpleDateFormat("dd/MM/yyyy HH:mm",new Locale("th","TH")).format(new Date()),22,false,Paint.Align.CENTER,content);lines.add(new Line("────────────────────────",20,false,Paint.Align.CENTER));JSONArray items=data.optJSONArray("items");if(items!=null)for(int i=0;i<items.length();i++){JSONObject item=items.getJSONObject(i);addWrapped(lines,item.optInt("qty",1)+" × "+item.optString("name",""),36,true,Paint.Align.LEFT,content);String detail=item.optString("detail","");if(!detail.isEmpty())for(String option:detail.split(" · "))addWrapped(lines,"• "+option,36,true,Paint.Align.LEFT,content-28);lines.add(new Line("────────────────────────",18,false,Paint.Align.CENTER));}String note=data.optString("note","");if(!note.isEmpty())addWrapped(lines,"หมายเหตุ: "+note,30,true,Paint.Align.LEFT,content);int height=54;for(Line line:lines)height+=(int)(line.size*1.45f);height+=52;Bitmap bitmap=Bitmap.createBitmap(width,Math.max(height,280),Bitmap.Config.ARGB_8888);Canvas canvas=new Canvas(bitmap);canvas.drawColor(Color.WHITE);Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);paint.setColor(Color.BLACK);float y=40;for(Line line:lines){paint.setTextSize(line.size);paint.setFakeBoldText(line.bold);paint.setTextAlign(line.align);float x=line.align==Paint.Align.CENTER?width/2f:line.align==Paint.Align.RIGHT?width-24:24;canvas.drawText(line.text,x,y,paint);y+=line.size*1.45f;}return bitmap;}
    private Bitmap renderReceipt(JSONObject data)throws Exception{final int width=576;final float content=528;List<Line> lines=new ArrayList<>();String header=data.optString("header","");if(!header.isEmpty())addWrapped(lines,header,27,true,Paint.Align.CENTER,content);addWrapped(lines,data.optString("table","Table -"),38,true,Paint.Align.CENTER,content);int guests=data.optInt("guests",0);if(guests>0)addWrapped(lines,"ลูกค้า "+guests+" คน",24,false,Paint.Align.CENTER,content);addWrapped(lines,new SimpleDateFormat("dd/MM/yyyy HH:mm",new Locale("th","TH")).format(new Date()),23,false,Paint.Align.CENTER,content);lines.add(new Line("────────────────────────",20,false,Paint.Align.CENTER));JSONArray items=data.optJSONArray("items");if(items!=null)for(int i=0;i<items.length();i++){JSONObject item=items.getJSONObject(i);addWrapped(lines,item.optInt("qty",1)+" × "+item.optString("name",""),31,true,Paint.Align.LEFT,content);String detail=item.optString("detail","");if(!detail.isEmpty())addWrapped(lines,detail,24,false,Paint.Align.LEFT,content-30);if(item.has("price"))addWrapped(lines,"฿"+String.format(Locale.US,"%.2f",item.optDouble("price",0)*item.optInt("qty",1)),28,true,Paint.Align.RIGHT,content);lines.add(new Line("────────────────────────",18,false,Paint.Align.CENTER));}String note=data.optString("note","");if(!note.isEmpty())addWrapped(lines,note,28,true,Paint.Align.LEFT,content);int height=230;for(Line line:lines)height+=(int)(line.size*1.48f);height+=55;Bitmap bitmap=Bitmap.createBitmap(width,Math.max(height,420),Bitmap.Config.ARGB_8888);Canvas canvas=new Canvas(bitmap);canvas.drawColor(Color.WHITE);Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);paint.setColor(Color.BLACK);Bitmap source=BitmapFactory.decodeResource(getResources(),R.drawable.receipt_logo);if(source!=null){canvas.drawBitmap(source,null,new Rect(218,10,358,150),paint);source.recycle();}float y=188;for(Line line:lines){paint.setTextSize(line.size);paint.setFakeBoldText(line.bold);paint.setTextAlign(line.align);float x=line.align==Paint.Align.CENTER?width/2f:line.align==Paint.Align.RIGHT?width-24:24;canvas.drawText(line.text,x,y,paint);y+=line.size*1.48f;}return bitmap;}
    private String defaultHost(String route){return "kitchen".equals(route)?"10.1.7.205":"receipt".equals(route)?"10.1.7.103":"10.1.7.102";}
    private String host(String route){return getSharedPreferences("printers",0).getString(route+"_host",defaultHost(route));}
    private int port(String route){return getSharedPreferences("printers",0).getInt(route+"_port",9100);}
    private void send(String route,Bitmap bitmap)throws Exception{try(Socket socket=new Socket()){socket.connect(new InetSocketAddress(host(route),port(route)),5000);socket.setSoTimeout(5000);OutputStream out=socket.getOutputStream();out.write(new byte[]{0x1b,0x40});out.write(raster(bitmap));out.write(new byte[]{0x0a,0x0a,0x0a,0x1d,0x56,0x00});out.flush();}finally{bitmap.recycle();}}
    private byte[] raster(Bitmap bmp)throws Exception{int w=(bmp.getWidth()+7)/8,h=bmp.getHeight();ByteArrayOutputStream out=new ByteArrayOutputStream();out.write(new byte[]{0x1d,0x76,0x30,0x00,(byte)(w&255),(byte)((w>>8)&255),(byte)(h&255),(byte)((h>>8)&255)});for(int y=0;y<h;y++)for(int xb=0;xb<w;xb++){int value=0;for(int bit=0;bit<8;bit++){int x=xb*8+bit;if(x<bmp.getWidth()){int color=bmp.getPixel(x,y),gray=(Color.red(color)+Color.green(color)+Color.blue(color))/3;if(gray<160)value|=1<<(7-bit);}}out.write(value);}return out.toByteArray();}
}
