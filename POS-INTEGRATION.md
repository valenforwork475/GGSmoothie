# GG Smoothie — คู่มือเชื่อม POS และโปรแกรมปริ้นสติกเกอร์

ทุกระบบใช้ Supabase ตัวเดียวกันเป็นศูนย์กลาง (schema อยู่ที่ `supabase/schema.sql`)

```
ลูกค้าสั่งจากเว็บ ──▶ Supabase (orders) ◀── POS หน้าร้าน (คิวเข้าเรียลไทม์ / ขาย walk-in)
                          │
                          └──▶ โปรแกรมปริ้นสติกเกอร์ (อ่านออเดอร์ → พิมพ์ฉลากแก้ว)
```

- Project URL: `https://qsylglypfjxincexteqy.supabase.co`
- ตาราง: `orders`, `menu_items`, `members`

## กุญแจ (สำคัญมาก)

| Key | ใช้ที่ไหน | สิทธิ์ |
|---|---|---|
| `sb_publishable_...` | เว็บไซต์ (ฝังอยู่ใน `index.html` แล้ว) | จำกัดด้วย RLS: อ่านเมนู + เรียก RPC เท่านั้น |
| `sb_secret_...` (หรือ legacy `service_role`) | **POS และโปรแกรมปริ้นเท่านั้น** | เต็ม — ข้าม RLS ทุกตาราง |

Secret key ดูได้ที่ Dashboard → Project Settings → API Keys
**ห้ามเอา secret key ไปใส่ในเว็บไซต์หรือโค้ดที่ส่งให้ browser เด็ดขาด** — POS เป็นโปรแกรมบนเครื่องร้านเราเองจึงใช้ได้

ทุก request จาก POS ใส่ header:

```
apikey: <SECRET_KEY>
Authorization: Bearer <SECRET_KEY>
Content-Type: application/json
```

## สถานะออเดอร์ (status flow)

```
pending → confirmed → making → ready → done
   └────────────────────────────▶ cancelled
```

เว็บฝั่งลูกค้า poll สถานะทุก 8 วินาที และแสดงข้อความไทยตามสถานะให้เอง — POS แค่อัปเดต status ให้ตรงขั้นตอน

## งานหลักของ POS

### 1. รับออเดอร์ใหม่ (เลือกอย่างใดอย่างหนึ่ง)

**แบบ poll (ง่ายสุด — แนะนำให้เริ่มจากอันนี้):**

```
GET /rest/v1/orders?status=eq.pending&order=created_at.asc
```

**แบบเรียลไทม์ (supabase-js):**

```js
import { createClient } from '@supabase/supabase-js';
const sb = createClient(SUPABASE_URL, SECRET_KEY);

sb.channel('orders')
  .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'orders' },
    (payload) => showNewOrder(payload.new))
  .subscribe();
```

### 2. อัปเดตสถานะ

```
PATCH /rest/v1/orders?id=eq.<uuid>
body: { "status": "making" }
```

### 3. ขาย walk-in หน้าร้าน (ให้ได้เลขคิวชุดเดียวกับเว็บ)

เรียก RPC เดียวกับเว็บ แต่ส่ง `p_source: "pos"`:

```
POST /rest/v1/rpc/place_order
body: {
  "p_name": "หน้าร้าน", "p_phone": "",
  "p_items": [{ "kind":"menu", "name":"กรีนโปรตีน", "qty":1, "price":129,
                "desc":"ผักโขม · กล้วย · โปรตีนถั่ว · อัลมอนด์",
                "cal":310, "p":24, "f":7, "sug":9 }],
  "p_total": 129, "p_pay_method": "cash", "p_source": "pos"
}
→ ตอบกลับ { "id": "<uuid>", "queue_no": 12, "status": "pending" }
```

เลขคิว (`queue_no`) รีเซ็ตเป็น 1 ทุกวันตามเวลาไทยโดยอัตโนมัติ

### 4. ให้แต้มสมาชิกตอนปิดออเดอร์ (`done`)

ออเดอร์มี `phone` ของลูกค้า (ถ้าลูกค้ากรอก) — บวกแต้มตามจำนวนแก้ว:

```
PATCH /rest/v1/members?phone=eq.<เบอร์>
body: { "stamps": <ค่าใหม่> }
```

หรืออ่านค่าเดิมก่อนด้วย `GET /rest/v1/members?phone=eq.<เบอร์>` แล้วค่อยบวก
เว็บฝั่งลูกค้าจะดึงแต้มล่าสุดจากเซิร์ฟเวอร์ให้เองตอนเปิดหน้า — **POS คือแหล่งความจริงของแต้ม**

### 5. แก้เมนู/ราคา/ปิดเมนูชั่วคราว

```
PATCH /rest/v1/menu_items?id=eq.g
body: { "price": 139 }          — เปลี่ยนราคา
body: { "active": false }       — ซ่อนเมนูจากหน้าเว็บ
```

เว็บอ่านเมนูจากตารางนี้ตอนโหลดหน้า (ถ้าอ่านไม่ได้จะ fallback เป็นเมนูที่ฝังในโค้ด)

## โปรแกรมปริ้นสติกเกอร์

คอลัมน์ `printed` (boolean) มีไว้ให้โดยเฉพาะ — วนลูปนี้:

1. ดึงออเดอร์ที่ร้านรับแล้วแต่ยังไม่ปริ้น:
   ```
   GET /rest/v1/orders?printed=eq.false&status=in.(confirmed,making)&order=created_at.asc
   ```
2. พิมพ์สติกเกอร์ 1 ใบต่อ 1 แก้ว (ดูข้อมูลจาก `items` ด้านล่าง — แก้วที่ `qty` > 1 พิมพ์ซ้ำตามจำนวน)
3. ตั้งค่าเรียบร้อย: `PATCH /rest/v1/orders?id=eq.<uuid>` body `{ "printed": true }`

### ข้อมูลใน `items` (jsonb array) — ครบพอสำหรับฉลากโภชนาการ

```json
{
  "kind": "menu",            // "menu" = เมนูปกติ, "custom" = สูตรจัดเอง
  "name": "กรีนโปรตีน",
  "qty": 2,
  "price": 129,
  "desc": "ผักโขม · กล้วย · โปรตีนถั่ว · อัลมอนด์",   // สูตรจัดเอง: รายการส่วนผสมที่ลูกค้าเลือก
  "cal": 310, "p": 24, "f": 7, "sug": 9              // แคลอรี่ / โปรตีน / ไฟเบอร์ / น้ำตาล (g)
}
```

### แนะนำเลย์เอาต์สติกเกอร์

```
┌──────────────────────────────┐
│  GG Smoothie        คิว #12  │
│  กรีนโปรตีน           (1/2)  │
│  ผักโขม·กล้วย·โปรตีนถั่ว     │
│  310 แคล · P24 F7 S9         │
│  คุณ วาเลน · พร้อมเพย์       │
└──────────────────────────────┘
```

ใช้ `queue_no`, `customer_name`, `pay_method` จากระดับออเดอร์ + ข้อมูลต่อแก้วจาก `items`

## เช็คลิสต์เปิดใช้งาน

1. [ ] เปิด Supabase Dashboard → SQL Editor → วางไฟล์ `supabase/schema.sql` ทั้งไฟล์ → Run
2. [ ] Deploy เว็บเวอร์ชันนี้ (key ฝังไว้ให้แล้ว) → ทดลองสั่ง 1 ออเดอร์จากหน้าเว็บ
3. [ ] เช็คใน Dashboard → Table Editor → `orders` ว่ามีออเดอร์เข้า
4. [ ] เก็บ secret key ไว้ใช้ตอนเขียน POS (อย่า commit ลง git)

## หมายเหตุความปลอดภัย

- ตาราง `orders` และ `members` **ไม่มี** policy ให้ publishable key อ่านตรง ๆ — คนทั่วไปดึงรายชื่อ/เบอร์ลูกค้าทั้งหมดไม่ได้ เว็บเข้าถึงได้เฉพาะผ่าน RPC ที่จำกัดขอบเขตแล้ว
- ราคาใน `p_total` มาจากฝั่ง client — POS ควรโชว์ยอดให้พนักงานเห็นก่อนยืนยันรับเงินเสมอ (ร้านตรวจสลิป/เก็บเงินเองอยู่แล้ว จึงยอมรับได้)
- ถ้าจะทำระบบแต้มมีมูลค่าสูงในอนาคต ค่อยเพิ่ม auth จริง (OTP เบอร์โทร) ภายหลังได้
