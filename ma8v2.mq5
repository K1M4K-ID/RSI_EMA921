//+------------------------------------------------------------------+
//|                                               MA8Martingale.mq5  |
//| Entry   : harga > SMA8 & SMA13(low) => fokus BUY                 |
//|           harga < SMA8 & SMA13(low) => fokus SELL                |
//| Validasi: break MA8 tapi belum break MA13 => bias tetap          |
//|           break MA13 + InpFlipPips => cut loss semua posisi      |
//|           arah lama, lalu buka basket arah baru                  |
//| Marti   : tambah layer saat harga melawan (ladder lot via input) |
//| Proteksi: basket profit tipis -> SL semua layer dikunci di       |
//|           (avg + lock) lalu di-trail                             |
//| Pyramid : harga jalan terus searah bias -> tambah posisi baru,   |
//|           tiap posisi punya SL+ sendiri yang ikut di-trail       |
//| REQUIRES a HEDGING account.                                      |
//| Magic basket = InpMagic, magic pyramid = InpMagic + 1            |
//+------------------------------------------------------------------+
#property copyright "K1M4K"
#property version   "4.10"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;    // basket martingale
CTrade tradeP;   // pyramid

//--- inputs
input group "=== Lot Martingale (atur sendiri) ==="
input string InpLotLadder        = "0.01x2,0.02x2,0.03x3,0.04x4,0.05x5,0.1x2"; // Format: lot x jumlah, pisah koma

input group "=== Moving Average ==="
input ENUM_TIMEFRAMES InpMATF    = PERIOD_CURRENT; // Timeframe MA
input int    InpMAPeriod         = 8;     // Periode SMA
input int    InpMABufferPts      = 0;     // Buffer break MA (points), 0 = tembus langsung

input group "=== MA 13 (validasi, applied to Low) ==="
input bool   InpUseMA13          = true;  // Aktifkan validasi MA13
input int    InpMA13Period       = 13;    // Periode SMA (price = Low)
input int    InpMA13Shift        = 0;     // 0 = bar berjalan, 1 = bar closed (lebih stabil)
input int    InpFlipPips         = 30;    // Jarak setelah break MA13 untuk cut loss + balik arah
input int    InpPipPoints        = 10;    // 1 pip = berapa points (XAUUSD 2 digit: 10 = 0.10)

input group "=== Martingale ==="
input int    InpGridStepPts      = 50;    // Jarak antar layer (points)

input group "=== Pyramid (ikut arah harga) ==="
input int    InpPyramidMax       = 5;     // Max posisi pyramid per arah (0 = off)
input int    InpPyramidStepPts   = 50;    // Jarak harga untuk tambah posisi pyramid (points)
input double InpPyramidLot       = 0.0;   // Lot pyramid (0 = pakai lot layer pertama)
input int    InpPyramidInitSLPts = 30;    // SL awal tiap posisi pyramid (points, 0 = tanpa SL awal)
input bool   InpPyramidNeedLock  = true;  // Pyramid hanya boleh kalau basket utama sudah ke-lock SL+

input group "=== Lock SL+ & Trailing (basket & pyramid) ==="
input int    InpLockActivatePts  = 20;    // Aktif kalau profit sudah sekian points
input int    InpLockPts          = 5;     // SL dikunci di +sekian points (isi >= spread+komisi)
input int    InpTrailStartPts    = 40;    // Trailing mulai kalau profit >= sekian points
input int    InpTrailDistPts     = 25;    // Jarak trailing dari harga (points)
input int    InpTrailStepPts     = 5;     // Minimal pergeseran SL per update (points)

input group "=== Safety ==="
input int    InpMaxSpreadPts     = 50;    // Max spread untuk buka order (0 = off)
input double InpEmergencyLoss    = 0.0;   // Tutup semua jika floating total <= -nilai ini (USD, 0 = off)
input int    InpReentryDelaySec  = 0;     // Jeda buka basket baru setelah basket tutup (0 = langsung)
input int    InpTradeGapMs       = 100;   // Jeda minimal antar order (ms)

input group "=== Panel ==="
input bool   InpShowPanel        = true;
input int    InpPanelX           = 10;
input int    InpPanelY           = 20;
input bool   InpResetStats       = false; // Reset statistik all-time saat EA dipasang

input group "=== General ==="
input long   InpMagic            = 20261120;
input int    InpSlippagePts      = 30;
input string InpComment          = "MA8MG";

//--- ladder
double g_lots[];
int    g_levels  = 0;
double g_pyrLot  = 0;
long   g_magicP  = 0;

//--- MA / bias
int    g_maHandle   = INVALID_HANDLE;
int    g_ma13Handle = INVALID_HANDLE;
double g_ma         = 0;
double g_ma13       = 0;
int    g_bias       = 0;   // +1 buy, -1 sell, 0 belum ada

//--- entry control (index: 1 = buy, 0 = sell)
int      g_prevCnt[2];
datetime g_nextEntry[2];
uint     g_lastTradeMs = 0;

//--- stats
double   g_maxProfitCyc = 0, g_maxLossCyc = 0;
double   g_maxProfitAll = 0, g_maxLossAll = 0;
datetime g_startTime    = 0;
int      g_prevTotal    = 0;
uint     g_lastPanelMs  = 0;
double   g_savedP = 0, g_savedL = 0;
string   g_gvP, g_gvL, g_gvS;

//--- panel
#define  ROWS    15
#define  PFX     "M8MG_"
#define  PANEL_W 380
#define  ROW_H   18

int Idx(int dir) { return dir == 1 ? 1 : 0; }

//+------------------------------------------------------------------+
double NormLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathRound(lot / step) * step;
   lot = MathMax(minv, MathMin(maxv, lot));
   return NormalizeDouble(lot, 2);
}

bool ParseLadder(string src)
{
   ArrayResize(g_lots, 0);

   string items[];
   int n = StringSplit(src, ',', items);
   if(n <= 0) return false;

   for(int i = 0; i < n; i++)
   {
      string it = items[i];
      StringTrimLeft(it);
      StringTrimRight(it);
      StringReplace(it, "X", "x");
      StringReplace(it, "*", "x");
      StringReplace(it, " ", "");
      if(it == "") continue;

      string p[];
      if(StringSplit(it, 'x', p) != 2) return false;

      double lot = StringToDouble(p[0]);
      int    cnt = (int)StringToInteger(p[1]);
      if(lot <= 0 || cnt <= 0) return false;

      lot = NormLot(lot);

      for(int k = 0; k < cnt; k++)
      {
         int sz = ArraySize(g_lots);
         if(sz >= 100) return false;
         ArrayResize(g_lots, sz + 1);
         g_lots[sz] = lot;
      }
   }
   g_levels = ArraySize(g_lots);
   return g_levels > 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Alert("EA ini butuh akun HEDGING. Akun sekarang bukan hedging.");
      return INIT_FAILED;
   }

   if(!ParseLadder(InpLotLadder))
   {
      Alert("Format InpLotLadder salah. Contoh: 0.01x2,0.02x2,0.03x3");
      return INIT_FAILED;
   }

   g_maHandle = iMA(_Symbol, InpMATF, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   if(g_maHandle == INVALID_HANDLE)
   {
      Alert("Gagal bikin handle MA.");
      return INIT_FAILED;
   }

   g_ma13Handle = iMA(_Symbol, InpMATF, InpMA13Period, 0, MODE_SMA, PRICE_LOW);
   if(g_ma13Handle == INVALID_HANDLE)
   {
      Alert("Gagal bikin handle MA13.");
      return INIT_FAILED;
   }

   g_magicP = InpMagic + 1;
   g_pyrLot = NormLot(InpPyramidLot > 0 ? InpPyramidLot : g_lots[0]);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   tradeP.SetExpertMagicNumber(g_magicP);
   tradeP.SetDeviationInPoints(InpSlippagePts);
   tradeP.SetTypeFillingBySymbol(_Symbol);

   g_prevCnt[0] = g_prevCnt[1] = 0;
   g_nextEntry[0] = g_nextEntry[1] = 0;

   string key = "M8MG_" + IntegerToString(InpMagic) + "_" + _Symbol;
   g_gvP = key + "_maxP";
   g_gvL = key + "_maxL";
   g_gvS = key + "_start";

   if(InpResetStats || !GlobalVariableCheck(g_gvS))
   {
      g_startTime    = TimeCurrent();
      g_maxProfitAll = 0;
      g_maxLossAll   = 0;
      GlobalVariableSet(g_gvS, (double)g_startTime);
      GlobalVariableSet(g_gvP, 0.0);
      GlobalVariableSet(g_gvL, 0.0);
   }
   else
   {
      g_startTime    = (datetime)GlobalVariableGet(g_gvS);
      g_maxProfitAll = GlobalVariableGet(g_gvP);
      g_maxLossAll   = GlobalVariableGet(g_gvL);
   }
   g_savedP = g_maxProfitAll;
   g_savedL = g_maxLossAll;

   double total = 0;
   for(int i = 0; i < g_levels; i++) total += g_lots[i];
   PrintFormat("Ladder siap: %d layer, total lot kalau semua kebuka = %.2f | lot pyramid %.2f x max %d",
               g_levels, total, g_pyrLot, InpPyramidMax);

   if(InpShowPanel) PanelCreate();
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_maHandle != INVALID_HANDLE)   IndicatorRelease(g_maHandle);
   if(g_ma13Handle != INVALID_HANDLE) IndicatorRelease(g_ma13Handle);
   ObjectsDeleteAll(0, PFX);
}

//+------------------------------------------------------------------+
//| Basket per arah & per magic                                      |
//+------------------------------------------------------------------+
struct SBasket
{
   int    count;
   double volume;
   double avg;
   double extreme;   // buy: open terendah, sell: open tertinggi (layer terdalam)
   double best;      // buy: open tertinggi, sell: open terendah (paling searah tren)
   double profit;
   double sl;        // SL terburuk di basket (0 = ada posisi tanpa SL)
};

void GetBasket(int dir, long magic, SBasket &b)
{
   b.count = 0; b.volume = 0; b.avg = 0; b.extreme = 0; b.best = 0; b.profit = 0; b.sl = 0;

   double sumPV = 0, slv = 0;
   bool   anyZero = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      int d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(d != dir) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double s   = PositionGetDouble(POSITION_SL);

      b.count++;
      b.volume += vol;
      sumPV    += vol * op;
      b.profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(b.count == 1) { b.extreme = op; b.best = op; }
      else if(dir == 1) { b.extreme = MathMin(b.extreme, op); b.best = MathMax(b.best, op); }
      else              { b.extreme = MathMax(b.extreme, op); b.best = MathMin(b.best, op); }

      if(s <= 0)            anyZero = true;
      else if(slv == 0)     slv = s;
      else                  slv = (dir == 1) ? MathMin(slv, s) : MathMax(slv, s);
   }
   if(b.volume > 0) b.avg = sumPV / b.volume;
   b.sl = anyZero ? 0 : slv;
}

//--- tutup SEMUA posisi arah tertentu (basket + pyramid)
void CloseDir(int dir)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long mg = PositionGetInteger(POSITION_MAGIC);
      if(mg != InpMagic && mg != g_magicP) continue;
      int d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(d != dir) continue;
      trade.PositionClose(t);
   }
}

void CloseAll()
{
   CloseDir(1);
   CloseDir(-1);
}

bool SpreadOK()
{
   if(InpMaxSpreadPts <= 0) return true;
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPts;
}

long MinStopLevel()
{
   return MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                  SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) + 2;
}

//+------------------------------------------------------------------+
//| MA & bias                                                        |
//+------------------------------------------------------------------+
bool UpdateMA()
{
   double buf[1];
   if(CopyBuffer(g_maHandle, 0, 0, 1, buf) < 1) return false;
   g_ma = buf[0];
   if(g_ma <= 0) return false;

   if(InpUseMA13)
   {
      double b13[1];
      if(CopyBuffer(g_ma13Handle, 0, InpMA13Shift, 1, b13) < 1) return false;
      g_ma13 = b13[0];
      if(g_ma13 <= 0) return false;
   }
   return true;
}

void UpdateBias()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double px    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buf   = InpMABufferPts * point;

   int nb = g_bias;

   if(!InpUseMA13)
   {
      // logika lama: break MA8 langsung balik
      if(px > g_ma + buf)      nb = 1;
      else if(px < g_ma - buf) nb = -1;
   }
   else
   {
      double flip = InpFlipPips * InpPipPoints * point;

      if(g_bias == 0)
      {
         // bias awal: harus di atas/bawah KEDUA MA
         if(px > g_ma + buf && px > g_ma13)      nb = 1;
         else if(px < g_ma - buf && px < g_ma13) nb = -1;
      }
      else if(g_bias == 1)
      {
         // break MA8 doang = tetap BUY. Balik SELL kalau sudah lewat MA13 sejauh flip
         if(px < g_ma - buf && px < g_ma13 - flip) nb = -1;
      }
      else
      {
         // break MA8 doang = tetap SELL. Balik BUY kalau sudah lewat MA13 sejauh flip
         if(px > g_ma + buf && px > g_ma13 + flip) nb = 1;
      }
   }

   if(nb != g_bias)
   {
      int old = g_bias;
      g_bias = nb;
      if(old != 0) CloseDir(old);   // cut loss semua posisi arah lama, basket arah baru buka via ManageEntry
   }
}

//+------------------------------------------------------------------+
//| Lock SL+ lalu trailing basket martingale                         |
//| SL semua layer = satu harga, jadi kalau kena total basket        |
//| = volume * (SL - avg) >= lock                                    |
//+------------------------------------------------------------------+
void ManageProtect(int dir, const SBasket &b)
{
   if(b.count == 0) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitPts = (dir == 1) ? (bid - b.avg) / point : (b.avg - ask) / point;
   if(profitPts < InpLockActivatePts) return;

   double desired = b.avg + dir * InpLockPts * point;

   if(profitPts >= InpTrailStartPts)
   {
      double tr = ((dir == 1) ? bid : ask) - dir * InpTrailDistPts * point;
      if(dir * (tr - desired) > 0) desired = tr;
   }
   desired = NormalizeDouble(desired, _Digits);

   double minD = MinStopLevel() * point;
   if(dir ==  1 && desired > bid - minD) return;
   if(dir == -1 && desired < ask + minD) return;

   if(b.sl != 0 && dir * (desired - b.sl) < InpTrailStepPts * point) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      int d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(d != dir) continue;

      double cur = PositionGetDouble(POSITION_SL);
      if(cur > 0 && MathAbs(cur - desired) < point * 0.5) continue;
      if(cur > 0 && dir * (desired - cur) <= 0) continue;   // SL tidak pernah mundur

      trade.PositionModify(t, desired, PositionGetDouble(POSITION_TP));
   }
}

//+------------------------------------------------------------------+
//| SL+ per posisi pyramid: lock di open+lock, lalu trailing         |
//+------------------------------------------------------------------+
void ManagePyramidProtect(int dir)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD  = MinStopLevel() * point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magicP) continue;
      int d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(d != dir) continue;

      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double cur = PositionGetDouble(POSITION_SL);
      double px  = (dir == 1) ? bid : ask;
      double pts = dir * (px - op) / point;
      if(pts < InpLockActivatePts) continue;

      double desired = op + dir * InpLockPts * point;
      if(pts >= InpTrailStartPts)
      {
         double tr = px - dir * InpTrailDistPts * point;
         if(dir * (tr - desired) > 0) desired = tr;
      }
      desired = NormalizeDouble(desired, _Digits);

      if(dir ==  1 && desired > bid - minD) continue;
      if(dir == -1 && desired < ask + minD) continue;
      if(cur > 0 && dir * (desired - cur) < InpTrailStepPts * point) continue;

      tradeP.PositionModify(t, desired, PositionGetDouble(POSITION_TP));
   }
}

//+------------------------------------------------------------------+
//| Entry & martingale (basket utama, arah bias)                     |
//+------------------------------------------------------------------+
bool TradeGap() { return (GetTickCount() - g_lastTradeMs) >= (uint)InpTradeGapMs; }

void ManageEntry(int dir, const SBasket &b)
{
   if(!SpreadOK() || !TradeGap()) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- belum ada basket di arah bias: langsung open
   if(b.count == 0)
   {
      if(TimeCurrent() < g_nextEntry[Idx(dir)]) return;
      bool ok = (dir == 1) ? trade.Buy (g_lots[0], _Symbol, 0, 0, 0, InpComment)
                           : trade.Sell(g_lots[0], _Symbol, 0, 0, 0, InpComment);
      if(ok) g_lastTradeMs = GetTickCount();
      return;
   }

   //--- martingale: tambah layer saat harga melawan
   if(b.count >= g_levels) return;

   double step = InpGridStepPts * point;
   double lot  = g_lots[b.count];
   bool   ok   = false;

   if(dir == 1 && ask <= b.extreme - step)
      ok = trade.Buy(lot, _Symbol, 0, 0, 0, InpComment);
   else if(dir == -1 && bid >= b.extreme + step)
      ok = trade.Sell(lot, _Symbol, 0, 0, 0, InpComment);

   if(ok) g_lastTradeMs = GetTickCount();
}

//+------------------------------------------------------------------+
//| Pyramid: harga jalan terus searah bias -> tambah posisi          |
//+------------------------------------------------------------------+
void ManagePyramid(int dir, const SBasket &base, const SBasket &pyr)
{
   if(InpPyramidMax <= 0) return;
   if(base.count == 0) return;                       // pyramid cuma kalau basket utama masih hidup
   if(pyr.count >= InpPyramidMax) return;
   if(InpPyramidNeedLock && base.sl == 0) return;    // profit basket harus sudah ke-lock dulu
   if(!SpreadOK() || !TradeGap()) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // posisi paling jauh searah tren (dari basket utama maupun pyramid)
   double front = base.best;
   if(pyr.count > 0)
      front = (dir == 1) ? MathMax(front, pyr.best) : MathMin(front, pyr.best);

   double step = InpPyramidStepPts * point;
   bool   go   = (dir == 1) ? (ask >= front + step) : (bid <= front - step);
   if(!go) return;

   double sl = 0;
   if(InpPyramidInitSLPts > 0)
   {
      double d = MathMax((long)InpPyramidInitSLPts, MinStopLevel()) * point;
      sl = NormalizeDouble((dir == 1) ? bid - d : ask + d, _Digits);
   }

   bool ok = (dir == 1) ? tradeP.Buy (g_pyrLot, _Symbol, 0, sl, 0, InpComment + "_P")
                        : tradeP.Sell(g_pyrLot, _Symbol, 0, sl, 0, InpComment + "_P");
   if(ok) g_lastTradeMs = GetTickCount();
}

//+------------------------------------------------------------------+
void UpdateStats(double floating, int totalCount)
{
   if(totalCount > 0 && g_prevTotal == 0)
   {
      g_maxProfitCyc = 0;
      g_maxLossCyc   = 0;
   }
   g_prevTotal = totalCount;

   if(totalCount == 0) return;

   if(floating > g_maxProfitCyc) g_maxProfitCyc = floating;
   if(floating < g_maxLossCyc)   g_maxLossCyc   = floating;
   if(floating > g_maxProfitAll) g_maxProfitAll = floating;
   if(floating < g_maxLossAll)   g_maxLossAll   = floating;
}

void Run()
{
   if(!UpdateMA()) return;
   UpdateBias();

   SBasket bb, sb, bp, sp;
   GetBasket( 1, InpMagic, bb);
   GetBasket(-1, InpMagic, sb);
   GetBasket( 1, g_magicP, bp);
   GetBasket(-1, g_magicP, sp);

   // catat waktu basket habis -> jeda re-entry
   if(bb.count == 0 && g_prevCnt[1] > 0) g_nextEntry[1] = TimeCurrent() + InpReentryDelaySec;
   if(sb.count == 0 && g_prevCnt[0] > 0) g_nextEntry[0] = TimeCurrent() + InpReentryDelaySec;
   g_prevCnt[1] = bb.count;
   g_prevCnt[0] = sb.count;

   double floating = bb.profit + sb.profit + bp.profit + sp.profit;
   int    totalCnt = bb.count + sb.count + bp.count + sp.count;
   UpdateStats(floating, totalCnt);

   //--- emergency
   if(InpEmergencyLoss > 0 && floating <= -InpEmergencyLoss)
   {
      CloseAll();
      return;
   }

   //--- proteksi SL+ / trailing
   ManageProtect( 1, bb);
   ManageProtect(-1, sb);
   ManagePyramidProtect( 1);
   ManagePyramidProtect(-1);

   //--- entry / marti / pyramid cuma di arah bias
   if(g_bias == 1)
   {
      ManageEntry(1, bb);
      ManagePyramid(1, bb, bp);
   }
   else if(g_bias == -1)
   {
      ManageEntry(-1, sb);
      ManagePyramid(-1, sb, sp);
   }
}

void OnTick()  { Run(); UpdatePanel(); }
void OnTimer() { UpdatePanel(); }

//+------------------------------------------------------------------+
double ClosedPnL(datetime from)
{
   if(!HistorySelect(from, TimeCurrent() + 86400)) return 0;

   double sum = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(tk == 0) continue;
      long mg = HistoryDealGetInteger(tk, DEAL_MAGIC);
      if(mg != InpMagic && mg != g_magicP) continue;
      if(HistoryDealGetString(tk, DEAL_SYMBOL) != _Symbol) continue;

      long type = HistoryDealGetInteger(tk, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;

      sum += HistoryDealGetDouble(tk, DEAL_PROFIT)
           + HistoryDealGetDouble(tk, DEAL_COMMISSION)
           + HistoryDealGetDouble(tk, DEAL_SWAP)
           + HistoryDealGetDouble(tk, DEAL_FEE);
   }
   return sum;
}

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void PanelCreate()
{
   string bg = PFX + "bg";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, PANEL_W);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, ROWS * ROW_H + 10);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,24,32');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,76,92');
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   for(int i = 0; i < ROWS; i++)
   {
      string n = PFX + "r" + IntegerToString(i);
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, InpPanelX + 8);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE, InpPanelY + 5 + i * ROW_H);
      ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, n, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetString(0, n, OBJPROP_TEXT, "");
   }
}

void SetRow(int i, string txt, color c = clrWhite)
{
   string n = PFX + "r" + IntegerToString(i);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
}

string Pad(string s, int w)
{
   while(StringLen(s) < w) s += " ";
   return s;
}

string Money(double v)
{
   return (v > 0 ? "+" : "") + DoubleToString(v, 2);
}

color PnLColor(double v)
{
   if(v > 0) return clrLime;
   if(v < 0) return clrTomato;
   return clrWhite;
}

string BasketLine(const SBasket &b)
{
   if(b.count == 0) return "-";
   return IntegerToString(b.count) + "/" + IntegerToString(g_levels) + "  "
        + DoubleToString(b.volume, 2) + " lot  avg " + DoubleToString(b.avg, _Digits);
}

string SLText(const SBasket &b)
{
   if(b.count == 0) return "";
   return b.sl > 0 ? "  SL " + DoubleToString(b.sl, _Digits) : "  SL -";
}

void UpdatePanel()
{
   if(g_maxProfitAll != g_savedP) { GlobalVariableSet(g_gvP, g_maxProfitAll); g_savedP = g_maxProfitAll; }
   if(g_maxLossAll   != g_savedL) { GlobalVariableSet(g_gvL, g_maxLossAll);   g_savedL = g_maxLossAll; }

   if(!InpShowPanel) return;

   uint now = GetTickCount();
   if(now - g_lastPanelMs < 500) return;
   g_lastPanelMs = now;

   SBasket bb, sb, bp, sp;
   GetBasket( 1, InpMagic, bb);
   GetBasket(-1, InpMagic, sb);
   GetBasket( 1, g_magicP, bp);
   GetBasket(-1, g_magicP, sp);
   double floating = bb.profit + sb.profit + bp.profit + sp.profit;

   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   double closedToday = ClosedPnL(dayStart);
   double closedTotal = ClosedPnL(g_startTime);

   string bias = g_bias == 1 ? "BUY  (harga > MA)" : (g_bias == -1 ? "SELL (harga < MA)" : "-");
   color  bc   = g_bias == 1 ? clrDeepSkyBlue : (g_bias == -1 ? clrOrange : clrWhite);

   SetRow(0,  "MA8Martingale  " + _Symbol, clrGold);
   SetRow(1,  Pad("Bias", 12) + ": " + bias, bc);
   SetRow(2,  Pad("MA8", 12) + ": " + DoubleToString(g_ma, _Digits) + "   spread " +
              IntegerToString((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)));
   SetRow(3,  Pad("MA13 (low)", 12) + ": " + (InpUseMA13 ? DoubleToString(g_ma13, _Digits) : "off"));
   SetRow(4,  Pad("BUY basket", 12) + ": " + BasketLine(bb), clrDeepSkyBlue);
   SetRow(5,  Pad("  floating", 12) + ": " + Money(bb.profit) + SLText(bb), PnLColor(bb.profit));
   SetRow(6,  Pad("SELL basket", 12) + ": " + BasketLine(sb), clrOrange);
   SetRow(7,  Pad("  floating", 12) + ": " + Money(sb.profit) + SLText(sb), PnLColor(sb.profit));
   SetRow(8,  Pad("Pyramid", 12) + ": BUY " + IntegerToString(bp.count) + "/" + IntegerToString(InpPyramidMax)
              + " (" + Money(bp.profit) + ")  SELL " + IntegerToString(sp.count) + "/" + IntegerToString(InpPyramidMax)
              + " (" + Money(sp.profit) + ")", clrWhite);
   SetRow(9,  Pad("Floating", 12) + ": " + Money(floating), PnLColor(floating));
   SetRow(10, Pad("Max profit", 12) + ": " + Money(g_maxProfitCyc) + " | " + Money(g_maxProfitAll) + "  (cyc|all)", clrLime);
   SetRow(11, Pad("Max loss", 12) + ": " + Money(g_maxLossCyc) + " | " + Money(g_maxLossAll) + "  (cyc|all)", clrTomato);
   SetRow(12, Pad("Closed today", 12) + ": " + Money(closedToday), PnLColor(closedToday));
   SetRow(13, Pad("Closed total", 12) + ": " + Money(closedTotal), PnLColor(closedTotal));
   SetRow(14, Pad("Equity", 12) + ": " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));

   ChartRedraw();
}
//+------------------------------------------------------------------+
