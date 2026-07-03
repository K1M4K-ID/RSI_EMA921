// Properti hak cipta, tautan, dan versi Expert Advisor
#property copyright "RoxyuDeveloper"
#property link      "https://roxyudeveloper.github.io/roxyu/"
#property version   "1.20"

// Sertakan file Trade.mqh untuk menggunakan kelas CTrade
#include <Trade\Trade.mqh>


// -------------------------------------------------------------------------------------------
//--- Parameter Input (Pengaturan yang bisa diubah dari jendela EA) ---
input string   InpLotTierList      = "0.01,0.02,0.05";      // Daftar Lot per Tier (pisah koma)
input int      InpLayerPerTier     = 40;                    // Jumlah Layer per Tier sebelum Lot Naik ke Tier Berikutnya
input int      InpMaxLayer         = 200;                   // Jumlah Maksimal Layer Grid
input int      InpJarakGrid        = 100;                   // Jarak Antar Layer (dalam Points)

// --- EMA Filter (diganti dari EMA5/9 -> EMA9/21) ---
input int      InpFastEMA          = 9;                     // Period EMA Cepat (dulu 5)
input int      InpSlowEMA          = 21;                    // Period EMA Lambat (dulu 9)

// --- RSI Filter ---
input int      InpRsiPeriod        = 9;                     // Period RSI
input double   InpRsiSellLowRisk   = 91.0;                  // RSI Sell Low Risk -> syarat entry Sell
input double   InpRsiSell          = 81.0;                  // RSI Sell (belum dipakai fase ini)
input double   InpRsiTpBuy         = 54.0;                  // RSI TP Buy (belum dipakai fase ini)
input double   InpRsiBreak         = 58.0;                  // RSI Break -> syarat entry Buy
input double   InpRsiTpSell        = 45.0;                  // RSI TP Sell (belum dipakai fase ini)
input double   InpRsiBuy           = 18.0;                  // RSI Buy (belum dipakai fase ini)
input double   InpRsiBuyLowRisk    = 9.0;                   // RSI Buy Low Risk (belum dipakai fase ini)

// --- BE & Trailing ---
input double   InpMulaiBE          = 100.0;                 // Jarak Poin mulai Break Even (Unified)
input double   InpTrailingStop     = 50.0;                  // Jarak Trailing Stop (dalam Points)
input double   InpTrailingStep     = 10.0;                  // Jarak Langkah Trailing (dalam Points)
input ulong    InpMagicNumber      = 123456;                // Magic Number
// --------------------------------------------------------------------------------------------


//--- Variabel Global ---
CTrade         trade;
int            fastHandle;
int            slowHandle;
int            rsiHandle;
double         fastBuffer[];
double         slowBuffer[];
double         rsiBuffer[];
double         pointValue;
double         g_lotTiers[];        // Hasil parse InpLotTierList jadi array angka

//--- Variabel Panel Statistik (persist lewat Global Variable terminal) ---
string         g_panelPrefix;       // Prefix unik buat GlobalVariable & Object Chart
int            g_maxLayerBuy  = 0;
int            g_maxLayerSell = 0;
double         g_maxFloatLossBuy    = 0;  // paling negatif (rugi terbesar), Buy
double         g_maxFloatLossSell   = 0;  // paling negatif, Sell
double         g_maxFloatLossTotal  = 0;  // paling negatif, gabungan Buy+Sell
double         g_maxFloatProfitBuy  = 0;  // paling positif, Buy
double         g_maxFloatProfitSell = 0;  // paling positif, Sell
double         g_maxFloatProfitTotal= 0;  // paling positif, gabungan
double         g_totalRealizedProfit= 0;  // total profit REALISASI (closed trades), bukan floating
double         g_startBalance       = 0;  // modal awal saat EA pertama kali jalan

//--- Profit Periodik (Harian/Mingguan/Bulanan), reset otomatis tiap ganti periode ---
double         g_dailyProfit    = 0;
double         g_weeklyProfit   = 0;
double         g_monthlyProfit  = 0;
datetime       g_dailyMarker    = 0;   // awal hari (00:00) periode berjalan
datetime       g_weeklyMarker   = 0;   // awal minggu (Senin 00:00) periode berjalan
datetime       g_monthlyMarker  = 0;   // awal bulan (tanggal 1, 00:00) periode berjalan

//--- Layout & Warna Panel (biar konsisten antar fungsi) ---
#define PNL_X        15
#define PNL_Y        15
#define PNL_W        280

#define Y_SEC1       (PNL_Y+48)
#define Y_ROW1       (Y_SEC1+18)
#define Y_ROW2       (Y_ROW1+17)
#define Y_SEC2       (Y_ROW2+24)
#define Y_ROW3       (Y_SEC2+18)
#define Y_ROW4       (Y_ROW3+17)
#define Y_ROW5       (Y_ROW4+17)
#define Y_SEC3       (Y_ROW5+24)
#define Y_ROW6       (Y_SEC3+18)
#define Y_ROW7       (Y_ROW6+17)
#define Y_ROW8       (Y_ROW7+17)
#define Y_SEC4       (Y_ROW8+24)
#define Y_ROW9       (Y_SEC4+18)
#define Y_ROW10      (Y_ROW9+17)
#define Y_ROW11      (Y_ROW10+17)
#define Y_SEC5       (Y_ROW11+24)
#define Y_ROW12      (Y_SEC5+18)
#define Y_ROW13      (Y_ROW12+17)
#define Y_ROW14      (Y_ROW13+17)
#define Y_BUTTON     (Y_ROW14+30)
#define PNL_H        (Y_BUTTON+42)

#define COL_BG        C'16,17,26'
#define COL_HEADER_BG C'34,38,58'
#define COL_BORDER    C'80,86,110'
#define COL_TITLE     C'255,205,90'
#define COL_SECTION   C'130,150,190'
#define COL_LABEL     C'190,192,205'
#define COL_POS       C'90,220,140'
#define COL_NEG       C'255,95,95'
#define COL_LOSS      C'255,110,110'
#define COL_PROFIT    C'95,190,255'

// --------------------------------------------------------------------------------------------


//| Fungsi inisialisasi EA (dijalankan sekali saat EA dipasang)      |
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   pointValue = _Point;

   // Handle EMA Cepat (default sekarang 9) & EMA Lambat (default sekarang 21)
   fastHandle = iMA(_Symbol, PERIOD_M1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, PERIOD_M1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   // Handle RSI filter tambahan
   rsiHandle  = iRSI(_Symbol, PERIOD_M1, InpRsiPeriod, PRICE_CLOSE);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
     {
      Print("Gagal membuat handle EMA Fast/Slow/RSI!");
      return(INIT_FAILED);
     }

   ArraySetAsSeries(fastBuffer, true);
   ArraySetAsSeries(slowBuffer, true);
   ArraySetAsSeries(rsiBuffer, true);

   // Parse InpLotTierList ("0.01,0.02,0.05") jadi array g_lotTiers[]
   string parts[];
   int total = StringSplit(InpLotTierList, ',', parts);
   if(total <= 0)
     {
      Print("InpLotTierList kosong/invalid! Contoh format yang benar: 0.01,0.02,0.05");
      return(INIT_FAILED);
     }
   ArrayResize(g_lotTiers, total);
   for(int i = 0; i < total; i++)
      g_lotTiers[i] = StringToDouble(parts[i]);

   // Setup panel statistik: prefix unik per symbol+magic biar gak bentrok EA lain
   g_panelPrefix = "GridEA_" + IntegerToString(InpMagicNumber) + "_" + _Symbol + "_";
   LoadPanelStats();

   // Catat modal awal SEKALI SAJA (kalau belum pernah tercatat sebelumnya)
   if(!GlobalVariableCheck(g_panelPrefix + "StartBalance"))
      GlobalVariableSet(g_panelPrefix + "StartBalance", AccountInfoDouble(ACCOUNT_BALANCE));
   g_startBalance = GlobalVariableGet(g_panelPrefix + "StartBalance");

   CheckPeriodRollover(); // pastikan marker harian/mingguan/bulanan valid begitu EA nyala

   CreatePanelBackground();
   CreateResetButton();

   return(INIT_SUCCEEDED);
  }



//| Fungsi deinisialisasi EA (dijalankan saat EA dilepas)            |
void OnDeinit(const int reason)
  {
   IndicatorRelease(fastHandle);
   IndicatorRelease(slowHandle);
   IndicatorRelease(rsiHandle);
   ObjectsDeleteAll(0, g_panelPrefix); // bersihin semua label & tombol panel
  }



//| Dipanggil otomatis oleh terminal tiap ada perubahan trade/deal.  |
//| Dipakai buat akumulasi TOTAL PROFIT REALISASI (bukan floating),  |
//| cuma ngitung deal CLOSE (DEAL_ENTRY_OUT) milik EA ini saja.      |
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket)) return;

   string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   ulong  dealMagic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

   // Hanya proses deal CLOSE (keluar posisi) milik symbol & magic number EA ini
   if(dealSymbol != _Symbol || dealMagic != InpMagicNumber) return;
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   double swap       = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
   double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   double netProfit  = profit + swap + commission;

   g_totalRealizedProfit += netProfit;
   GlobalVariableSet(g_panelPrefix + "TotalRealizedProfit", g_totalRealizedProfit);

   // Pastikan periode (hari/minggu/bulan) masih valid sebelum nambahin, biar gak nyasar ke periode lama
   CheckPeriodRollover();

   g_dailyProfit   += netProfit;
   g_weeklyProfit  += netProfit;
   g_monthlyProfit += netProfit;
   GlobalVariableSet(g_panelPrefix + "DailyProfit",   g_dailyProfit);
   GlobalVariableSet(g_panelPrefix + "WeeklyProfit",  g_weeklyProfit);
   GlobalVariableSet(g_panelPrefix + "MonthlyProfit", g_monthlyProfit);
  }



//| Cek apakah sudah masuk hari/minggu/bulan baru; kalau iya, reset  |
//| akumulator periode yang bersangkutan ke 0. Dipanggil di OnInit,  |
//| OnTick, dan OnTradeTransaction supaya selalu up to date.         |
void CheckPeriodRollover()
  {
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   // --- Awal hari ini (00:00) ---
   MqlDateTime dayDt = dt;
   dayDt.hour = 0; dayDt.min = 0; dayDt.sec = 0;
   datetime todayStart = StructToTime(dayDt);

   if(todayStart != g_dailyMarker)
     {
      g_dailyMarker = todayStart;
      g_dailyProfit = 0;
      GlobalVariableSet(g_panelPrefix + "DailyMarker", (double)g_dailyMarker);
      GlobalVariableSet(g_panelPrefix + "DailyProfit", g_dailyProfit);
     }

   // --- Awal minggu ini (Senin 00:00) ---
   // dt.day_of_week: 0=Minggu, 1=Senin, ..., 6=Sabtu
   int daysSinceMonday = (dt.day_of_week == 0) ? 6 : (dt.day_of_week - 1);
   datetime weekStart = todayStart - (daysSinceMonday * 86400);

   if(weekStart != g_weeklyMarker)
     {
      g_weeklyMarker = weekStart;
      g_weeklyProfit = 0;
      GlobalVariableSet(g_panelPrefix + "WeeklyMarker", (double)g_weeklyMarker);
      GlobalVariableSet(g_panelPrefix + "WeeklyProfit", g_weeklyProfit);
     }

   // --- Awal bulan ini (tanggal 1, 00:00) ---
   MqlDateTime monthDt = dt;
   monthDt.day = 1; monthDt.hour = 0; monthDt.min = 0; monthDt.sec = 0;
   datetime monthStart = StructToTime(monthDt);

   if(monthStart != g_monthlyMarker)
     {
      g_monthlyMarker = monthStart;
      g_monthlyProfit = 0;
      GlobalVariableSet(g_panelPrefix + "MonthlyMarker", (double)g_monthlyMarker);
      GlobalVariableSet(g_panelPrefix + "MonthlyProfit", g_monthlyProfit);
     }
  }



//| Fungsi utama yang dijalankan setiap ada perubahan harga (tick)   |
void OnTick()
  {
   // Salin nilai EMA Fast, EMA Slow, dan RSI terkini
   if(CopyBuffer(fastHandle, 0, 0, 1, fastBuffer) <= 0) return;
   if(CopyBuffer(slowHandle, 0, 0, 1, slowBuffer) <= 0) return;
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // --- SINYAL BUY: harga break di atas EMA Fast (9) DAN EMA Slow (21) DAN RSI break di atas InpRsiBreak (58) ---
   bool focusBuy = (ask > fastBuffer[0]) && (ask > slowBuffer[0]) && (rsiBuffer[0] > InpRsiBreak);

   // --- SINYAL SELL: harga break di bawah EMA Fast (9) DAN EMA Slow (21) DAN RSI masuk zona low risk (>= 91) ---
   bool focusSell = (bid < fastBuffer[0]) && (bid < slowBuffer[0]) && (rsiBuffer[0] >= InpRsiSellLowRisk);

   int buyCount = 0;
   int sellCount = 0;
   CalculatePositions(buyCount, sellCount);

   //--- LOGIKA 1 ARAH (ONE DIRECTION) - GRID AVERAGING SEARAH TREND, KHUSUS BUY ---
   if(buyCount > 0)
     {
      if(buyCount < InpMaxLayer)
        {
         double lastBuyPrice = GetLastOrderPrice(POSITION_TYPE_BUY);
         if(lastBuyPrice > 0 && ask <= lastBuyPrice - (InpJarakGrid * pointValue))
           {
            double nextLot = CalculateNextLot(buyCount);
            trade.Buy(nextLot, _Symbol, ask, 0, 0, "Buy Avg Layer " + IntegerToString(buyCount + 1));
           }
        }
     }
   //--- BAGIAN: LOGIKA BUKA POSISI PERTAMA BUY ---
   else
     {
      if(focusBuy)
        {
         double firstLot = CalculateNextLot(0); // layer 1 -> tier 0 -> g_lotTiers[0]
         trade.Buy(firstLot, _Symbol, ask, 0, 0, "First Buy Layer 1");
        }
     }

   //--- LOGIKA 1 ARAH (ONE DIRECTION) - GRID AVERAGING SEARAH TREND, KHUSUS SELL ---
   if(sellCount > 0)
     {
      if(sellCount < InpMaxLayer)
        {
         double lastSellPrice = GetLastOrderPrice(POSITION_TYPE_SELL);
         if(lastSellPrice > 0 && bid >= lastSellPrice + (InpJarakGrid * pointValue))
           {
            double nextLot = CalculateNextLot(sellCount);
            trade.Sell(nextLot, _Symbol, bid, 0, 0, "Sell Avg Layer " + IntegerToString(sellCount + 1));
           }
        }
     }
   //--- BAGIAN: LOGIKA BUKA POSISI PERTAMA SELL (zona low risk RSI >= 91) ---
   else
     {
      if(focusSell)
        {
         double firstLot = CalculateNextLot(0);
         trade.Sell(firstLot, _Symbol, bid, 0, 0, "First Sell Layer 1 - Low Risk 91");
        }
     }

   //--- LOGIKA BREAK EVEN & TRAILING STOP TERPUSAT (UNIFIED), Buy & Sell ---
   CalculatePositions(buyCount, sellCount); // refresh count setelah kemungkinan entry baru
   if(buyCount > 0) ManageUnifiedBE(POSITION_TYPE_BUY);
   if(sellCount > 0) ManageUnifiedBE(POSITION_TYPE_SELL);

   //--- UPDATE STATISTIK & GAMBAR PANEL ---
   CheckPeriodRollover(); // deteksi ganti hari/minggu/bulan (misal market baru buka Senin)
   double floatBuy = 0, floatSell = 0;
   GetFloatingProfit(POSITION_TYPE_BUY, floatBuy);
   GetFloatingProfit(POSITION_TYPE_SELL, floatSell);
   UpdateStats(buyCount, sellCount, floatBuy, floatSell);
   DrawPanel(buyCount, sellCount, floatBuy, floatSell);
  }



//| Fungsi Menghitung Jumlah Posisi Buy & Sell yang Terbuka          |
void CalculatePositions(int &buyCount, int &sellCount)
  {
   buyCount = 0;
   sellCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyCount++;
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) sellCount++;
        }
     }
  }



//| Fungsi Mendapatkan Harga Pembukaan dari Posisi Terakhir          |
double GetLastOrderPrice(ENUM_POSITION_TYPE type)
  {
   double lastPrice = 0;
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         if(PositionGetInteger(POSITION_TYPE) == type)
           {
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            if(openTime > lastTime)
              {
               lastTime = openTime;
               lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
              }
           }
        }
     }
   return lastPrice;
  }



//| Fungsi Menutup Semua Posisi Berdasarkan Tipe (standby, belum dipanggil - buat switch-direction fase depan) |
void CloseAllPositions(ENUM_POSITION_TYPE type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         if(PositionGetInteger(POSITION_TYPE) == type)
           {
            trade.PositionClose(ticket);
           }
        }
     }
  }



//| Fungsi Menghitung Lot Berikutnya - LOT PER TIER (CUSTOM LIST)    |
//| currentCount = jumlah layer yang sudah terbuka saat ini          |
//| Lot ikut g_lotTiers[] sesuai tier: layer 1..40 = tier 0,          |
//| layer 41..80 = tier 1, layer 81..120 = tier 2, dst.               |
//| Kalau tier melebihi panjang list, pakai nilai TERAKHIR di list.  |
double CalculateNextLot(int currentCount)
  {
   int nextLayer = currentCount + 1;                          // layer yang mau dibuka sekarang
   int tier = (nextLayer - 1) / InpLayerPerTier;               // tier ke-0 = layer 1..40, tier ke-1 = layer 41..80, dst

   int lastTierIndex = ArraySize(g_lotTiers) - 1;
   if(tier > lastTierIndex) tier = lastTierIndex;              // clamp ke tier terakhir yang ada di list
   if(tier < 0) tier = 0;

   double nextLot = g_lotTiers[tier];

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   nextLot = MathRound(nextLot / stepLot) * stepLot;
   if(nextLot < minLot) nextLot = minLot;
   if(nextLot > maxLot) nextLot = maxLot;

   return nextLot;
  }



//| Fungsi untuk Mengelola Break Even & Trailing Stop Serentak       |
void ManageUnifiedBE(ENUM_POSITION_TYPE type)
  {
   double totalVolume = 0;
   double totalCost = 0;
   double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         if(PositionGetInteger(POSITION_TYPE) == type)
           {
            double vol = PositionGetDouble(POSITION_VOLUME);
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            totalVolume += vol;
            totalCost += (vol * openPrice);
           }
        }
     }

   if(totalVolume == 0) return;
   double bePrice = totalCost / totalVolume;

   double profitPoints = 0;
   if(type == POSITION_TYPE_BUY)
      profitPoints = (currentPrice - bePrice) / pointValue;
   else
      profitPoints = (bePrice - currentPrice) / pointValue;

   if(profitPoints >= InpMulaiBE)
     {
      double targetSL = bePrice;

      if(profitPoints >= InpMulaiBE + InpTrailingStop)
        {
         if(type == POSITION_TYPE_BUY)
            targetSL = currentPrice - (InpTrailingStop * pointValue);
         else
            targetSL = currentPrice + (InpTrailingStop * pointValue);
        }

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
           {
            if(PositionGetInteger(POSITION_TYPE) == type)
              {
               double currentSL = PositionGetDouble(POSITION_SL);
               double currentTP = PositionGetDouble(POSITION_TP);

               bool shouldModify = false;
               double stepPoints = InpTrailingStep * pointValue;

               if(type == POSITION_TYPE_BUY)
                 {
                  if(currentSL == 0)
                     shouldModify = true;
                  else if((targetSL - currentSL) >= stepPoints)
                     shouldModify = true;
                 }
               else
                 {
                  if(currentSL == 0)
                     shouldModify = true;
                  else if((currentSL - targetSL) >= stepPoints)
                     shouldModify = true;
                 }

               if(shouldModify)
                 {
                  targetSL = NormalizeDouble(targetSL, _Digits);
                  trade.PositionModify(ticket, targetSL, currentTP);
                 }
              }
           }
        }
     }
  }



//+------------------------------------------------------------------+
//|                     PANEL STATISTIK MONITOR                      |
//+------------------------------------------------------------------+

//| Ambil total floating profit/loss (currency akun) untuk 1 arah    |
void GetFloatingProfit(ENUM_POSITION_TYPE type, double &floatingProfit)
  {
   floatingProfit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         if(PositionGetInteger(POSITION_TYPE) == type)
           {
            floatingProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
           }
        }
     }
  }



//| Helper baca 1 Global Variable, default 0 kalau belum ada         |
double LoadGV(string name)
  {
   if(GlobalVariableCheck(name)) return GlobalVariableGet(name);
   return 0;
  }



//| Load semua statistik lama dari Global Variable terminal           |
//| (biar gak reset ke 0 kalau EA di-reload/compile ulang)            |
void LoadPanelStats()
  {
   g_maxLayerBuy         = (int)LoadGV(g_panelPrefix + "MaxLayerBuy");
   g_maxLayerSell         = (int)LoadGV(g_panelPrefix + "MaxLayerSell");
   g_maxFloatLossBuy      = LoadGV(g_panelPrefix + "MaxFloatLossBuy");
   g_maxFloatLossSell     = LoadGV(g_panelPrefix + "MaxFloatLossSell");
   g_maxFloatLossTotal    = LoadGV(g_panelPrefix + "MaxFloatLossTotal");
   g_maxFloatProfitBuy    = LoadGV(g_panelPrefix + "MaxFloatProfitBuy");
   g_maxFloatProfitSell   = LoadGV(g_panelPrefix + "MaxFloatProfitSell");
   g_maxFloatProfitTotal  = LoadGV(g_panelPrefix + "MaxFloatProfitTotal");
   g_totalRealizedProfit  = LoadGV(g_panelPrefix + "TotalRealizedProfit");

   g_dailyProfit    = LoadGV(g_panelPrefix + "DailyProfit");
   g_weeklyProfit   = LoadGV(g_panelPrefix + "WeeklyProfit");
   g_monthlyProfit  = LoadGV(g_panelPrefix + "MonthlyProfit");
   g_dailyMarker    = (datetime)LoadGV(g_panelPrefix + "DailyMarker");
   g_weeklyMarker   = (datetime)LoadGV(g_panelPrefix + "WeeklyMarker");
   g_monthlyMarker  = (datetime)LoadGV(g_panelPrefix + "MonthlyMarker");
  }



//| Reset semua statistik (dipanggil pas tombol Reset diklik)        |
void ResetPanelStats()
  {
   g_maxLayerBuy = 0; g_maxLayerSell = 0;
   g_maxFloatLossBuy = 0; g_maxFloatLossSell = 0; g_maxFloatLossTotal = 0;
   g_maxFloatProfitBuy = 0; g_maxFloatProfitSell = 0; g_maxFloatProfitTotal = 0;
   g_totalRealizedProfit = 0;
   g_startBalance = AccountInfoDouble(ACCOUNT_BALANCE); // modal awal di-set ulang dari saldo sekarang

   g_dailyProfit = 0; g_weeklyProfit = 0; g_monthlyProfit = 0;
   g_dailyMarker = 0; g_weeklyMarker = 0; g_monthlyMarker = 0;

   GlobalVariableDel(g_panelPrefix + "MaxLayerBuy");
   GlobalVariableDel(g_panelPrefix + "MaxLayerSell");
   GlobalVariableDel(g_panelPrefix + "MaxFloatLossBuy");
   GlobalVariableDel(g_panelPrefix + "MaxFloatLossSell");
   GlobalVariableDel(g_panelPrefix + "MaxFloatLossTotal");
   GlobalVariableDel(g_panelPrefix + "MaxFloatProfitBuy");
   GlobalVariableDel(g_panelPrefix + "MaxFloatProfitSell");
   GlobalVariableDel(g_panelPrefix + "MaxFloatProfitTotal");
   GlobalVariableDel(g_panelPrefix + "TotalRealizedProfit");
   GlobalVariableDel(g_panelPrefix + "DailyProfit");
   GlobalVariableDel(g_panelPrefix + "WeeklyProfit");
   GlobalVariableDel(g_panelPrefix + "MonthlyProfit");
   GlobalVariableDel(g_panelPrefix + "DailyMarker");
   GlobalVariableDel(g_panelPrefix + "WeeklyMarker");
   GlobalVariableDel(g_panelPrefix + "MonthlyMarker");
   GlobalVariableSet(g_panelPrefix + "StartBalance", g_startBalance);

   CheckPeriodRollover(); // set ulang marker periode dari titik reset ini
  }



//| Update rekor statistik kalau ada nilai baru yang lebih ekstrem   |
void UpdateStats(int buyCount, int sellCount, double floatBuy, double floatSell)
  {
   double floatTotal = floatBuy + floatSell;

   if(buyCount > g_maxLayerBuy)
     {
      g_maxLayerBuy = buyCount;
      GlobalVariableSet(g_panelPrefix + "MaxLayerBuy", g_maxLayerBuy);
     }
   if(sellCount > g_maxLayerSell)
     {
      g_maxLayerSell = sellCount;
      GlobalVariableSet(g_panelPrefix + "MaxLayerSell", g_maxLayerSell);
     }

   if(floatBuy < g_maxFloatLossBuy)
     {
      g_maxFloatLossBuy = floatBuy;
      GlobalVariableSet(g_panelPrefix + "MaxFloatLossBuy", g_maxFloatLossBuy);
     }
   if(floatBuy > g_maxFloatProfitBuy)
     {
      g_maxFloatProfitBuy = floatBuy;
      GlobalVariableSet(g_panelPrefix + "MaxFloatProfitBuy", g_maxFloatProfitBuy);
     }

   if(floatSell < g_maxFloatLossSell)
     {
      g_maxFloatLossSell = floatSell;
      GlobalVariableSet(g_panelPrefix + "MaxFloatLossSell", g_maxFloatLossSell);
     }
   if(floatSell > g_maxFloatProfitSell)
     {
      g_maxFloatProfitSell = floatSell;
      GlobalVariableSet(g_panelPrefix + "MaxFloatProfitSell", g_maxFloatProfitSell);
     }

   if(floatTotal < g_maxFloatLossTotal)
     {
      g_maxFloatLossTotal = floatTotal;
      GlobalVariableSet(g_panelPrefix + "MaxFloatLossTotal", g_maxFloatLossTotal);
     }
   if(floatTotal > g_maxFloatProfitTotal)
     {
      g_maxFloatProfitTotal = floatTotal;
      GlobalVariableSet(g_panelPrefix + "MaxFloatProfitTotal", g_maxFloatProfitTotal);
     }
  }



//| Bikin background panel (header bar + body) - dipanggil sekali    |
void CreatePanelBackground()
  {
   string bg = g_panelPrefix + "BG_Body";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, PNL_X - 6);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, PNL_Y - 6);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, PNL_W);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, PNL_H);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, COL_BG);
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, COL_BORDER);
      ObjectSetInteger(0, bg, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }

   string hdr = g_panelPrefix + "BG_Header";
   if(ObjectFind(0, hdr) < 0)
     {
      ObjectCreate(0, hdr, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, hdr, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, hdr, OBJPROP_XDISTANCE, PNL_X - 6);
      ObjectSetInteger(0, hdr, OBJPROP_YDISTANCE, PNL_Y - 6);
      ObjectSetInteger(0, hdr, OBJPROP_XSIZE, PNL_W);
      ObjectSetInteger(0, hdr, OBJPROP_YSIZE, 34);
      ObjectSetInteger(0, hdr, OBJPROP_BGCOLOR, COL_HEADER_BG);
      ObjectSetInteger(0, hdr, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, hdr, OBJPROP_COLOR, COL_BORDER);
      ObjectSetInteger(0, hdr, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, hdr, OBJPROP_BACK, false);
      ObjectSetInteger(0, hdr, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, hdr, OBJPROP_HIDDEN, true);
     }

   SetPanelLabel(g_panelPrefix + "L_Title", "GRID EA MONITOR", PNL_Y + 8, COL_TITLE, 10, true);
  }



//| Helper bikin/update 1 baris label biasa (judul/section)          |
void SetPanelLabel(string name, string text, int y, color clr, int fontSize = 9, bool bold = false)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PNL_X + 10);
      ObjectSetString(0, name, OBJPROP_FONT, bold ? "Consolas Bold" : "Consolas");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }



//| Helper bikin/update 1 baris "label : value" 2 kolom rapi         |
void SetPanelRow(string baseName, string label, string value, int y, color valueClr)
  {
   string lblName = baseName + "_lbl";
   string valName = baseName + "_val";

   if(ObjectFind(0, lblName) < 0)
     {
      ObjectCreate(0, lblName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, lblName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, lblName, OBJPROP_XDISTANCE, PNL_X + 18);
      ObjectSetString(0, lblName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, lblName, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, lblName, OBJPROP_COLOR, COL_LABEL);
      ObjectSetInteger(0, lblName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lblName, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, lblName, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, lblName, OBJPROP_TEXT, label);

   if(ObjectFind(0, valName) < 0)
     {
      ObjectCreate(0, valName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, valName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, valName, OBJPROP_XDISTANCE, PNL_X + 155);
      ObjectSetString(0, valName, OBJPROP_FONT, "Consolas Bold");
      ObjectSetInteger(0, valName, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, valName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, valName, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, valName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, valName, OBJPROP_COLOR, valueClr);
   ObjectSetString(0, valName, OBJPROP_TEXT, value);
  }



//| Bikin tombol Reset Stats (dipanggil sekali di OnInit)            |
void CreateResetButton()
  {
   string name = g_panelPrefix + "BtnReset";
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PNL_X + 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, Y_BUTTON);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, PNL_W - 32);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, 24);
      ObjectSetString(0, name, OBJPROP_TEXT, "Reset Panel Stats");
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas Bold");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, C'120,32,40');
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, COL_BORDER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }



//| Gambar/refresh seluruh isi panel tiap tick                       |
void DrawPanel(int buyCount, int sellCount, double floatBuy, double floatSell)
  {
   double floatTotal = floatBuy + floatSell;
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   string pfx = g_panelPrefix;

   // --- Section: Posisi ---
   SetPanelLabel(pfx + "S1", "POSISI AKTIF", Y_SEC1, COL_SECTION, 8, true);
   SetPanelRow(pfx + "R1", "Layer Buy",  IntegerToString(buyCount)  + "  (Max " + IntegerToString(g_maxLayerBuy)  + ")", Y_ROW1, clrWhite);
   SetPanelRow(pfx + "R2", "Layer Sell", IntegerToString(sellCount) + "  (Max " + IntegerToString(g_maxLayerSell) + ")", Y_ROW2, clrWhite);

   // --- Section: Floating Sekarang ---
   SetPanelLabel(pfx + "S2", "FLOATING SEKARANG", Y_SEC2, COL_SECTION, 8, true);
   SetPanelRow(pfx + "R3", "Buy",   DoubleToString(floatBuy, 2)   + " " + cur, Y_ROW3, (floatBuy   >= 0 ? COL_POS : COL_NEG));
   SetPanelRow(pfx + "R4", "Sell",  DoubleToString(floatSell, 2)  + " " + cur, Y_ROW4, (floatSell  >= 0 ? COL_POS : COL_NEG));
   SetPanelRow(pfx + "R5", "Total", DoubleToString(floatTotal, 2) + " " + cur, Y_ROW5, (floatTotal >= 0 ? COL_POS : COL_NEG));

   // --- Section: Rekor Max Loss ---
   SetPanelLabel(pfx + "S3", "REKOR MAX FLOATING LOSS", Y_SEC3, COL_SECTION, 8, true);
   SetPanelRow(pfx + "R6", "Buy",   DoubleToString(g_maxFloatLossBuy, 2)   + " " + cur, Y_ROW6, COL_LOSS);
   SetPanelRow(pfx + "R7", "Sell",  DoubleToString(g_maxFloatLossSell, 2)  + " " + cur, Y_ROW7, COL_LOSS);
   SetPanelRow(pfx + "R8", "Total", DoubleToString(g_maxFloatLossTotal, 2) + " " + cur, Y_ROW8, COL_LOSS);

   // --- Section: Total Profit dari Modal (REALISASI, bukan floating) ---
   double profitPercent = (g_startBalance > 0) ? (g_totalRealizedProfit / g_startBalance * 100.0) : 0.0;
   color  profitClr = (g_totalRealizedProfit >= 0 ? COL_PROFIT : COL_NEG);

   SetPanelLabel(pfx + "S4", "TOTAL PROFIT DARI MODAL", Y_SEC4, COL_SECTION, 8, true);
   SetPanelRow(pfx + "R9",  "Profit Total", DoubleToString(g_totalRealizedProfit, 2) + " " + cur, Y_ROW9,  profitClr);
   SetPanelRow(pfx + "R10", "Dari Modal",   DoubleToString(profitPercent, 2) + " %",              Y_ROW10, profitClr);
   SetPanelRow(pfx + "R11", "Modal Awal",   DoubleToString(g_startBalance, 2) + " " + cur,         Y_ROW11, clrWhite);

   // --- Section: Profit Periodik (reset otomatis tiap ganti hari/minggu/bulan) ---
   SetPanelLabel(pfx + "S5", "PROFIT PERIODIK (REALISASI)", Y_SEC5, COL_SECTION, 8, true);
   SetPanelRow(pfx + "R12", "Harian",   DoubleToString(g_dailyProfit, 2)   + " " + cur, Y_ROW12, (g_dailyProfit   >= 0 ? COL_PROFIT : COL_NEG));
   SetPanelRow(pfx + "R13", "Mingguan", DoubleToString(g_weeklyProfit, 2)  + " " + cur, Y_ROW13, (g_weeklyProfit  >= 0 ? COL_PROFIT : COL_NEG));
   SetPanelRow(pfx + "R14", "Bulanan",  DoubleToString(g_monthlyProfit, 2) + " " + cur, Y_ROW14, (g_monthlyProfit >= 0 ? COL_PROFIT : COL_NEG));

   ChartRedraw(0);
  }



//| Tangani klik tombol Reset di panel                                |
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == g_panelPrefix + "BtnReset")
     {
      ResetPanelStats();
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false); // un-press tombolnya
      ChartRedraw(0);
     }
  }
//+------------------------------------------------------------------+
