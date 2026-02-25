#if __INTELLISENSE__
#include "cppIntellisense.h"
#endif

// Keep settings in Main.as because user-folder plugin builds do not support #include.
[Setting category="Display" name="Window Visible"]
bool S_WindowVisible = true;

[Setting category="Display" name="Hide with game UI"]
bool S_HideWithGameUi = false;

[Setting category="Display" name="Window position"]
vec2 S_WindowPos = vec2(40, 360);

[Setting category="Display" name="Lock window position"]
bool S_LockWindowPos = false;

[Setting category="Display" name="Rows visible" min=6 max=40]
int S_MaxRows = 14;

[Setting category="Display" name="Show speed column"]
bool S_ShowSpeed = true;

[Setting category="Display" name="Show cumulative column"]
bool S_ShowCumulative = false;

[Setting category="Display" name="Auto-hide when not driving"]
bool S_AutoHideWhenNotDriving = true;

[Setting category="Display" name="Keep visible on finish/improve screen"]
bool S_ShowOnImproveScreen = true;

[Setting category="Display" name="Show Ghost column"]
bool S_ShowWR = true;

[Setting category="Timing" name="UI/engine blend tolerance (ms)" min=1 max=100]
int S_TimingBlendToleranceMs = 20;

[Setting category="Data" name="Save data to disk"]
bool S_SaveData = true;

[Setting category="Data" name="Save best splits from partial runs (give up/restart)"]
bool S_SavePartialBests = true;

[Setting category="Data" name="Auto-migrate legacy BestCP data"]
bool S_AutoMigrateLegacy = true;

[Setting category="Data" name="Use Personal Best ghost for PB sync"]
bool S_UsePbGhostSync = true;

[Setting category="Data" name="Reset map data"]
bool S_ResetMapData = false;

[Setting category="Feedback" name="Flash on new PB"]
bool S_FlashOnPb = true;

[Setting category="Feedback" name="Notify on new PB"]
bool S_NotifyOnPb = true;

[Setting category="Ghost" name="Ghost splits (comma/newline; mm:ss.xxx or ms)"]
string S_WrSplits = "";

const string kDataVersion = "2.0";

string g_MapUid = "";
string g_DataFile = "";
bool g_WaitForRunStart = true;
bool g_RunFinished = false;
int g_LastLandmark = -1;
int g_LastCheckpointRaceMs = 0;
int g_TotalCheckpoints = 0;
int g_CheckpointsThisRun = 0;
int g_Laps = 1;
bool g_IsLapRace = false;

array<int> g_CurrentSplits;
array<int> g_CurrentCumulative;
array<int> g_CurrentSpeeds;
array<int> g_RunLandmarks;
array<int> g_BestSplits;
array<int> g_PbSplits;
array<int> g_RunBaselineBestSplits;
array<int> g_WrSplitsParsed;
array<int> g_WrSplitsAuto;
array<int> g_EmptySplits;
string g_WrGhostName = "";
int g_WrGhostTime = 0;
uint g_LastWrPollAt = 0;
uint g_LastWrLiveAt = 0;
bool g_WrDepsNoticeShown = false;
bool g_LegacyMigratedThisMap = false;
int g_PbTime = 0;
uint g_PbFlashUntil = 0;
bool g_HasLastFinishDeltaVsPb = false;
int g_LastFinishDeltaVsPb = 0;

void Main() {}

void OnDestroyed() {
  SaveData();
}

void OnSettingsChanged() {
  if (S_ResetMapData) {
    S_ResetMapData = false;
    g_BestSplits.RemoveRange(0, g_BestSplits.Length);
    g_PbSplits.RemoveRange(0, g_PbSplits.Length);
    g_PbTime = 0;
    SaveData();
  }
  ParseWrSplitsSetting();
}

void Update(float dt) {
  string uid = GetMapUid();
  if (uid != g_MapUid) {
    CommitPartialRunBestSplits();
    if (g_MapUid.Length > 0) SaveData();
    LoadMap(uid);
    return;
  }

  if (uid.Length == 0) return;
  MaybeNotifyWrDepsMissing();
  if (Time::Now > g_LastWrPollAt + 750) {
    g_LastWrPollAt = Time::Now;
    TrySyncPbFromPersonalBestGhost();
    TryUpdateAutoWrFromGhosts();
  }
  if (!IsPlayerReady()) {
    // Give up / restart can make the player briefly "not ready" before timer rewind logic runs.
    // Commit partial bests here so completed CP splits are not lost.
    CommitPartialRunBestSplits();
    g_WaitForRunStart = true;
    return;
  }

  int raceNow = GetCurrentPlayerRaceTimeMs();
  int landmarkNow = GetCurrentCheckpointLandmark();

  // If timer rewinds during a run (give up/restart/launched respawn),
  // trim run state to the respawn checkpoint instead of keeping stale rows.
  if (!g_WaitForRunStart && g_LastCheckpointRaceMs > 0) {
    if (raceNow <= 0) {
      CommitPartialRunBestSplits();
      ResetRunState();
      g_WaitForRunStart = false;
      return;
    }
    if (raceNow + 50 < g_LastCheckpointRaceMs) {
      if (TryRewindRunState(raceNow, landmarkNow)) {
        g_WaitForRunStart = false;
        return;
      }
      CommitPartialRunBestSplits();
      ResetRunState();
      g_WaitForRunStart = false;
      return;
    }
  }

  if (g_WaitForRunStart) {
    // After finish, clear immediately once player hits improve/give up (spawn checkpoint),
    // otherwise keep the finished run visible while sitting on finish.
    if (g_RunFinished && raceNow > 0 && landmarkNow != GetSpawnCheckpoint()) return;
    CommitPartialRunBestSplits();
    ResetRunState();
    g_WaitForRunStart = false;
    return;
  }

  if (g_TotalCheckpoints <= 0) {
    TryResolveTotalCheckpoints();
  }

  int landmark = landmarkNow;
  if (landmark < 0 || landmark == g_LastLandmark) return;

  // Launched respawn can jump back to an earlier checkpoint while race timer keeps running.
  // In that case, truncate rows back to that CP and continue from there.
  int rewindIx = FindRunLandmarkIndex(landmark);
  if (rewindIx >= 0 && rewindIx < int(g_RunLandmarks.Length) - 1) {
    // Save achieved splits before truncating run state (restart/respawn path).
    CommitPartialRunBestSplits();
    ApplyRunRewind(rewindIx, raceNow);
    g_LastLandmark = landmark;
    return;
  }

  g_LastLandmark = landmark;

  if (!IsRelevantLandmark(landmark)) return;

  int raceTime = ResolveCheckpointRaceTimeMs();
  if (raceTime <= 0) return;

  int split = raceTime - g_LastCheckpointRaceMs;
  if (split <= 0 && g_LastCheckpointRaceMs > 0) return;

  g_LastCheckpointRaceMs = raceTime;
  g_CheckpointsThisRun++;
  g_CurrentSplits.InsertLast(split);
  g_CurrentCumulative.InsertLast(raceTime);
  g_CurrentSpeeds.InsertLast(GetPlayerSpeedKmh());
  g_RunLandmarks.InsertLast(landmark);

  bool reachedEnd = IsFinishLandmark(landmark)
      || (g_TotalCheckpoints > 0 && g_CheckpointsThisRun >= g_TotalCheckpoints);
  if (reachedEnd) {
    FinalizeRun();
    g_WaitForRunStart = true;
  }
}

void LoadMap(const string &in uid) {
  g_MapUid = uid;
  g_DataFile = "";
  g_TotalCheckpoints = 0;
  g_Laps = 1;
  g_IsLapRace = false;
  g_BestSplits.RemoveRange(0, g_BestSplits.Length);
  g_PbSplits.RemoveRange(0, g_PbSplits.Length);
  g_WrSplitsAuto.RemoveRange(0, g_WrSplitsAuto.Length);
  g_WrGhostName = "";
  g_WrGhostTime = 0;
  g_LastWrPollAt = 0;
  g_WrDepsNoticeShown = false;
  g_LegacyMigratedThisMap = false;
  g_PbTime = 0;
  ResetRunState();

  if (uid.Length == 0) return;

  auto map = GetApp().RootMap;
  if (map is null) return;

  g_Laps = Math::Max(1, map.TMObjective_NbLaps);
  g_IsLapRace = map.TMObjective_IsLapRace;

  int perLap = CountCheckpointsPerLap();
  if (perLap > 0) {
    g_TotalCheckpoints = g_IsLapRace ? perLap * g_Laps : perLap;
  }

  LoadData();
  ParseWrSplitsSetting();
  if (g_TotalCheckpoints <= 0) {
    g_TotalCheckpoints = Math::Max(int(g_PbSplits.Length), int(g_BestSplits.Length));
  }
}

void ResetRunState() {
  g_RunFinished = false;
  g_HasLastFinishDeltaVsPb = false;
  g_LastFinishDeltaVsPb = 0;
  g_RunBaselineBestSplits = g_BestSplits;
  g_LastLandmark = GetSpawnCheckpoint();
  g_LastCheckpointRaceMs = 0;
  g_CheckpointsThisRun = 0;
  g_CurrentSplits.RemoveRange(0, g_CurrentSplits.Length);
  g_CurrentCumulative.RemoveRange(0, g_CurrentCumulative.Length);
  g_CurrentSpeeds.RemoveRange(0, g_CurrentSpeeds.Length);
  g_RunLandmarks.RemoveRange(0, g_RunLandmarks.Length);
}

void FinalizeRun() {
  if (g_CurrentCumulative.Length == 0) return;
  g_RunFinished = true;

  int runTime = g_CurrentCumulative[g_CurrentCumulative.Length - 1];
  if (runTime <= 0) return;

  // Snapshot finish-vs-previous-PB delta before mutating PB/best.
  if (g_PbTime > 0) {
    g_HasLastFinishDeltaVsPb = true;
    g_LastFinishDeltaVsPb = runTime - g_PbTime;
  } else {
    g_HasLastFinishDeltaVsPb = false;
    g_LastFinishDeltaVsPb = 0;
  }

  if (g_TotalCheckpoints <= 0) {
    g_TotalCheckpoints = int(g_CurrentSplits.Length);
  }
  if (g_TotalCheckpoints > 0 && g_CurrentSplits.Length != uint(g_TotalCheckpoints)) {
    bool noBaseline = g_PbSplits.Length == 0 && g_BestSplits.Length == 0;
    if (noBaseline) g_TotalCheckpoints = int(g_CurrentSplits.Length);
    else return;
  }

  bool hasBest = g_BestSplits.Length == g_CurrentSplits.Length;
  if (!hasBest) {
    g_BestSplits = g_CurrentSplits;
  } else {
    for (uint i = 0; i < g_BestSplits.Length; i++) {
      if (g_CurrentSplits[i] < g_BestSplits[i]) g_BestSplits[i] = g_CurrentSplits[i];
    }
  }

  bool newPb = g_PbTime == 0 || runTime < g_PbTime || g_PbSplits.Length != g_CurrentSplits.Length;
  if (newPb) {
    g_PbTime = runTime;
    g_PbSplits = g_CurrentSplits;
  }

  if (newPb) {
    if (S_FlashOnPb) g_PbFlashUntil = Time::Now + 1700;
    if (S_NotifyOnPb) UI::ShowNotification("Checkpoint Pace", "New PB: " + Time::Format(runTime));
  }

  SaveData();
}

bool MergeSplitsIntoBest(const array<int> &in sourceSplits) {
  if (sourceSplits.Length == 0) return false;

  bool changed = false;
  if (g_BestSplits.Length == 0) {
    g_BestSplits = sourceSplits;
    return true;
  }

  uint overlap = Math::Min(g_BestSplits.Length, sourceSplits.Length);
  for (uint i = 0; i < overlap; i++) {
    int sp = sourceSplits[i];
    if (sp > 0 && sp < g_BestSplits[i]) {
      g_BestSplits[i] = sp;
      changed = true;
    }
  }

  // If this run reached farther than previous best data, append missing checkpoints.
  if (sourceSplits.Length > g_BestSplits.Length) {
    for (uint i = g_BestSplits.Length; i < sourceSplits.Length; i++) {
      int sp = sourceSplits[i];
      if (sp <= 0) break;
      g_BestSplits.InsertLast(sp);
      changed = true;
    }
  }

  return changed;
}

void CommitPartialRunBestSplits() {
  if (!S_SavePartialBests) return;
  if (g_RunFinished) return;
  if (g_CurrentSplits.Length == 0) return;
  if (!MergeSplitsIntoBest(g_CurrentSplits)) return;
  SaveData();
}

int CountCheckpointsPerLap() {
  auto pg = cast<CSmArenaClient>(GetApp().CurrentPlayground);
  if (pg is null || pg.Arena is null) return 0;
  auto landmarks = pg.Arena.MapLandmarks;

  int cp = 1;
  array<int> linkedOrders;
  for (uint i = 0; i < landmarks.Length; i++) {
    auto lm = landmarks[i];
    if (lm is null || lm.Waypoint is null) continue;
    if (lm.Waypoint.IsMultiLap) continue;
    if (lm.Waypoint.IsFinish) continue;

    if (lm.Tag == "Checkpoint") {
      cp++;
    } else if (lm.Tag == "LinkedCheckpoint") {
      if (linkedOrders.Find(lm.Order) < 0) {
        linkedOrders.InsertLast(lm.Order);
        cp++;
      }
    } else {
      cp++;
    }
  }
  return cp;
}

bool IsRelevantLandmark(int ix) {
  auto pg = cast<CSmArenaClient>(GetApp().CurrentPlayground);
  if (pg is null || pg.Arena is null) return false;
  auto landmarks = pg.Arena.MapLandmarks;
  if (ix < 0 || ix >= int(landmarks.Length)) return false;
  auto lm = landmarks[ix];
  if (lm is null || lm.Waypoint is null) return false;
  if (lm.Waypoint.IsFinish) return true;
  if (lm.Tag == "Checkpoint" || lm.Tag == "LinkedCheckpoint") return true;
  return false;
}

bool IsFinishLandmark(int ix) {
  auto pg = cast<CSmArenaClient>(GetApp().CurrentPlayground);
  if (pg is null || pg.Arena is null) return false;
  auto landmarks = pg.Arena.MapLandmarks;
  if (ix < 0 || ix >= int(landmarks.Length)) return false;
  auto lm = landmarks[ix];
  return lm !is null && lm.Waypoint !is null && lm.Waypoint.IsFinish;
}

int FindRunLandmarkIndex(int landmark) {
  for (int i = int(g_RunLandmarks.Length) - 1; i >= 0; i--) {
    if (g_RunLandmarks[i] == landmark) return i;
  }
  return -1;
}

void ApplyRunRewind(int keepIndex, int raceNow) {
  int keepLen = keepIndex + 1;
  if (keepLen < 0) keepLen = 0;

  if (g_CurrentSplits.Length > uint(keepLen)) g_CurrentSplits.RemoveRange(keepLen, g_CurrentSplits.Length - keepLen);
  if (g_CurrentCumulative.Length > uint(keepLen)) g_CurrentCumulative.RemoveRange(keepLen, g_CurrentCumulative.Length - keepLen);
  if (g_CurrentSpeeds.Length > uint(keepLen)) g_CurrentSpeeds.RemoveRange(keepLen, g_CurrentSpeeds.Length - keepLen);
  if (g_RunLandmarks.Length > uint(keepLen)) g_RunLandmarks.RemoveRange(keepLen, g_RunLandmarks.Length - keepLen);
  g_CheckpointsThisRun = keepLen;

  if (keepLen <= 0) {
    g_LastCheckpointRaceMs = 0;
    g_LastLandmark = GetSpawnCheckpoint();
    return;
  }

  if (raceNow > 0 && raceNow >= g_CurrentCumulative[keepLen - 1]) {
    g_CurrentCumulative[keepLen - 1] = raceNow;
    g_LastCheckpointRaceMs = raceNow;
  } else {
    g_LastCheckpointRaceMs = g_CurrentCumulative[keepLen - 1];
  }
  g_LastLandmark = g_RunLandmarks[keepLen - 1];
}

bool TryRewindRunState(int raceNow, int landmarkNow) {
  if (raceNow <= 0) return false;

  int keepIx = -1;

  // Prefer exact landmark match when available.
  if (landmarkNow >= 0) {
    keepIx = FindRunLandmarkIndex(landmarkNow);
  }

  // Fallback: find latest cumulative checkpoint that is <= current race time.
  if (keepIx < 0) {
    for (int i = int(g_CurrentCumulative.Length) - 1; i >= 0; i--) {
      if (g_CurrentCumulative[i] <= raceNow) { keepIx = i; break; }
    }
  }

  if (keepIx < 0) return false;
  if (keepIx < int(g_CurrentSplits.Length) - 1) {
    // Save achieved splits before truncating run state (restart/respawn path).
    CommitPartialRunBestSplits();
  }
  ApplyRunRewind(keepIx, raceNow);
  return true;
}

void TryResolveTotalCheckpoints() {
  int perLap = CountCheckpointsPerLap();
  if (perLap > 0) {
    g_TotalCheckpoints = g_IsLapRace ? perLap * g_Laps : perLap;
    return;
  }
  int fromData = Math::Max(int(g_PbSplits.Length), int(g_BestSplits.Length));
  if (fromData > 0) g_TotalCheckpoints = fromData;
}

int GetPlayerSpeedKmh() {
  auto sp = GetPlayerScript();
  if (sp is null) return -1;
  int speed = sp.DisplaySpeed;
  if (speed != 0) return speed;
  return int(Math::Round(sp.Velocity.Length() * 3.6f));
}

int GetCurrentCheckpointLandmark() {
  auto p = GetPlayer();
  if (p is null) return -1;
  return p.CurrentLaunchedRespawnLandmarkIndex;
}

CSmPlayer@ GetPlayer() {
  auto pg = cast<CSmArenaClient>(GetApp().CurrentPlayground);
  if (pg is null || pg.GameTerminals.Length != 1) return null;
  return cast<CSmPlayer>(pg.GameTerminals[0].GUIPlayer);
}

CSmScriptPlayer@ GetPlayerScript() {
  auto p = GetPlayer();
  if (p is null) return null;
  return cast<CSmScriptPlayer>(p.ScriptAPI);
}

bool IsPlayerReady() {
  auto scriptPlayer = GetPlayerScript();
  if (scriptPlayer is null) return false;
  return GetCurrentPlayerRaceTimeMs() >= 0
      && scriptPlayer.Post == CSmScriptPlayer::EPost::CarDriver
      && GetSpawnCheckpoint() != -1;
}

int GetSpawnCheckpoint() {
  auto p = GetPlayer();
  if (p is null) return -1;
  return p.SpawnIndex;
}

int GetCurrentPlayerRaceTimeMs() {
  auto pg = cast<CSmArenaClient>(GetApp().CurrentPlayground);
  if (pg is null || pg.Interface is null || pg.Interface.ManialinkScriptHandler is null) return -1;
  int gameTime = pg.Interface.ManialinkScriptHandler.GameTime;
  auto p = GetPlayer();
  if (p is null) return -1;
  return gameTime - p.StartTime;
}

int ResolveCheckpointRaceTimeMs() {
  int estimate = GetCurrentPlayerRaceTimeMs();
  int uiTime = GetUICheckpointTimeMs();
  if (uiTime >= 0) return uiTime;
  return estimate;
}

int NormalizeUiCheckpointTime(int uiTime, int estimate) {
  if (estimate <= 0) return uiTime;
  if (Math::Abs(uiTime - estimate) <= 3) return uiTime;
  if (Math::Abs(uiTime * 10 - estimate) <= 80) return uiTime * 10;
  if (Math::Abs(uiTime * 100 - estimate) <= 800) return uiTime * 100;
  return uiTime;
}

int GetUICheckpointTimeMs() {
  auto net = GetApp().Network;
  if (net is null) return -1;
  auto appPg = net.ClientManiaAppPlayground;
  if (appPg is null) return -1;

  // Match TM-AI approach: find the active checkpoint UI layer dynamically.
  for (uint i = 0; i < appPg.UILayers.Length; i++) {
    auto layer = appPg.UILayers[i];
    if (layer is null || !layer.IsVisible || layer.LocalPage is null) continue;

    auto cpFrame = cast<CGameManialinkFrame>(layer.LocalPage.GetFirstChild("Race_Checkpoint"));
    if (cpFrame is null) continue;

    auto raceTimeFrame = cast<CGameManialinkFrame>(cpFrame.GetFirstChild("frame-race-time"));
    if (raceTimeFrame !is null) {
      for (uint j = 0; j < raceTimeFrame.Controls.Length; j++) {
        auto label = cast<CGameManialinkLabel>(raceTimeFrame.Controls[j]);
        if (label is null || label.Value.Length == 0) continue;
        int parsed = Time::ParseRelativeTime(label.Value);
        if (parsed > 0) return parsed;
      }
    }

    // Fallback for layouts that don't expose named children.
    if (cpFrame.Controls.Length == 0) continue;
    auto frameCheckpoint = cast<CGameManialinkFrame>(cpFrame.Controls[0]);
    if (frameCheckpoint is null || frameCheckpoint.Controls.Length == 0) continue;
    auto frameRace = cast<CGameManialinkFrame>(frameCheckpoint.Controls[0]);
    if (frameRace is null || frameRace.Controls.Length == 0) continue;
    auto frameRaceTime2 = cast<CGameManialinkFrame>(frameRace.Controls[0]);
    if (frameRaceTime2 is null || frameRaceTime2.Controls.Length < 2) continue;
    auto label2 = cast<CGameManialinkLabel>(frameRaceTime2.Controls[1]);
    if (label2 is null || label2.Value.Length == 0) continue;
    int parsed2 = Time::ParseRelativeTime(label2.Value);
    if (parsed2 > 0) return parsed2;
  }

  return -1;
}

int ParseRaceTimeTextMs(const string &in inputRaw) {
  string input;
  for (int i = 0; i < inputRaw.Length; i++) {
    uint8 c = inputRaw[uint(i)];
    bool digit = c >= 48 && c <= 57;
    if (digit || c == 58 || c == 46) {
      input += " ";
      input[input.Length - 1] = c;
    }
  }

  int colon = -1;
  int dot = -1;
  for (int i = 0; i < input.Length; i++) {
    if (input[uint(i)] == 58) colon = i;
    if (input[uint(i)] == 46) dot = i;
  }
  if (colon < 0 || dot < 0 || dot < colon) return -1;

  string minutesStr = input.SubStr(0, colon);
  string secondsStr = input.SubStr(colon + 1, dot - colon - 1);
  string fracStr = input.SubStr(dot + 1);

  int minutes = Text::ParseInt(minutesStr);
  int seconds = Text::ParseInt(secondsStr);
  if (minutes < 0 || seconds < 0) return -1;

  int frac = 0;
  if (fracStr.Length == 1) {
    frac = Text::ParseInt(fracStr) * 100;
  } else if (fracStr.Length == 2) {
    frac = Text::ParseInt(fracStr) * 10;
  } else if (fracStr.Length >= 3) {
    frac = Text::ParseInt(fracStr.SubStr(0, 3));
  }

  return minutes * 60000 + seconds * 1000 + frac;
}

string GetMapUid() {
  auto app = cast<CTrackMania>(GetApp());
  if (app.RootMap is null) return "";
  return app.RootMap.IdName;
}

int SumRange(const array<int> &in data, uint from, uint to) {
  int sum = 0;
  if (to > data.Length) to = data.Length;
  for (uint i = from; i < to; i++) sum += data[i];
  return sum;
}

int GetTheoreticalBest() {
  if (g_BestSplits.Length == 0) return 0;
  return SumRange(g_BestSplits, 0, g_BestSplits.Length);
}

int GetEstimatedFinish() {
  if (g_BestSplits.Length == 0) return 0;
  uint done = g_CurrentSplits.Length;
  int now = SumRange(g_CurrentSplits, 0, done);
  int remaining = SumRange(g_BestSplits, done, g_BestSplits.Length);
  return now + remaining;
}

int GetCurrentVsBestDelta() {
  uint done = g_CurrentSplits.Length;
  if (done == 0 || g_BestSplits.Length < done) return 0;
  int curr = SumRange(g_CurrentSplits, 0, done);
  int best = SumRange(g_BestSplits, 0, done);
  return curr - best;
}

int GetPbCumulativeAt(uint indexInclusive) {
  if (g_PbSplits.Length == 0 || indexInclusive >= g_PbSplits.Length) return 0;
  return SumRange(g_PbSplits, 0, indexInclusive + 1);
}

int GetBestSplitForDeltaAt(int index) {
  if (index < 0) return 0;
  if (index < int(g_RunBaselineBestSplits.Length)) return g_RunBaselineBestSplits[index];
  if (index < int(g_BestSplits.Length)) return g_BestSplits[index];
  return 0;
}

int GetCurrentVsWrDelta() {
  uint done = g_CurrentSplits.Length;
  const array<int>@ wrRef = GetActiveWrSplitsRef();
  if (done == 0 || wrRef.Length < done) return 0;
  int curr = SumRange(g_CurrentSplits, 0, done);
  int wr = SumRange(wrRef, 0, done);
  return curr - wr;
}

int GetBestVsWrDelta() {
  const array<int>@ wrRef = GetActiveWrSplitsRef();
  if (g_BestSplits.Length == 0 || wrRef.Length == 0) return 0;
  uint n = Math::Min(g_BestSplits.Length, wrRef.Length);
  int best = SumRange(g_BestSplits, 0, n);
  int wr = SumRange(wrRef, 0, n);
  return best - wr;
}

int GetWrTotal() {
  const array<int>@ wrRef = GetActiveWrSplitsRef();
  if (wrRef.Length == 0) return 0;
  return SumRange(wrRef, 0, wrRef.Length);
}

const array<int>@ GetActiveWrSplitsRef() {
  if (!HasWrDeps() || !IsWrFeatureAvailable()) return g_EmptySplits;
  if (g_WrSplitsAuto.Length > 0) return g_WrSplitsAuto; // live and cached both come from auto
  return g_EmptySplits;
}

int GetWrSplitCount() {
  const array<int>@ wrRef = GetActiveWrSplitsRef();
  return int(wrRef.Length);
}

string GetWrSourceLabel() {
  if (!HasWrDeps() || !IsWrFeatureAvailable()) return "Missing";
  if (IsWrLiveNow()) {
    if (g_WrGhostName.Length > 0) return "Live (" + g_WrGhostName + ")";
    return "Live";
  }
  if (g_WrSplitsAuto.Length > 0) return "Cached";
  return "Missing";
}

bool HasWrDeps() {
#if DEPENDENCY_MLFEEDRACEDATA
  return true;
#else
  return false;
#endif
}

bool IsWrFeatureAvailable() {
#if DEPENDENCY_MLFEEDRACEDATA
  auto gd = MLFeed::GetGhostData();
  return gd !is null;
#else
  return false;
#endif
}

bool IsWrLiveNow() {
  if (!HasWrDeps() || !IsWrFeatureAvailable()) return false;
  if (g_WrSplitsAuto.Length == 0) return false;
  return g_LastWrLiveAt > 0 && Time::Now <= g_LastWrLiveAt + 1500;
}

void MaybeNotifyWrDepsMissing() {
  if (!S_ShowWR || g_WrDepsNoticeShown) return;
  if (HasWrDeps() && IsWrFeatureAvailable()) return;
  g_WrDepsNoticeShown = true;
  UI::ShowNotification(
    "Checkpoint Pace",
    "Ghost mode needs MLFeedRaceData + MLHook. Install/enable both plugins to use ghost splits and ghost delta."
  );
}

string GetCheckpointLabel(int index) {
  if (g_TotalCheckpoints > 0 && index == g_TotalCheckpoints - 1) return "Finish";
  return "" + (index + 1);
}

string TrimStr(const string &in s) {
  int a = 0;
  int b = int(s.Length) - 1;
  while (a <= b && (s[a] == 32 || s[a] == 9 || s[a] == 10 || s[a] == 13)) a++;
  while (b >= a && (s[b] == 32 || s[b] == 9 || s[b] == 10 || s[b] == 13)) b--;
  if (b < a) return "";
  return s.SubStr(a, b - a + 1);
}

int ParseWrTokenMs(const string &in tokenRaw) {
  string token = TrimStr(tokenRaw);
  if (token.Length == 0) return -1;

  int parsed = Time::ParseRelativeTime(token);
  if (parsed > 0) return parsed;

  bool digitsOnly = true;
  for (uint i = 0; i < token.Length; i++) {
    if (token[i] < 48 || token[i] > 57) { digitsOnly = false; break; }
  }
  if (!digitsOnly) return -1;

  int ms = Text::ParseInt(token);
  return ms > 0 ? ms : -1;
}

void ParseWrSplitsSetting() {
  g_WrSplitsParsed.RemoveRange(0, g_WrSplitsParsed.Length);
  if (S_WrSplits.Length == 0) return;

  string cur = "";
  for (uint i = 0; i < S_WrSplits.Length; i++) {
    uint8 c = S_WrSplits[i];
    bool sep = c == 44 || c == 10 || c == 13 || c == 59 || c == 124 || c == 9;
    if (sep) {
      int v = ParseWrTokenMs(cur);
      if (v > 0) g_WrSplitsParsed.InsertLast(v);
      cur = "";
    } else {
      cur += " ";
      cur[cur.Length - 1] = c;
    }
  }
  int v2 = ParseWrTokenMs(cur);
  if (v2 > 0) g_WrSplitsParsed.InsertLast(v2);
}

bool BuildSplitsFromCumulative(const array<uint>@ cps, array<int>@ outSplits) {
  outSplits.RemoveRange(0, outSplits.Length);
  if (cps is null || cps.Length == 0) return false;

  int prev = 0;
  for (uint i = 0; i < cps.Length; i++) {
    int now = int(cps[i]);
    if (now <= prev) return false;
    outSplits.InsertLast(now - prev);
    prev = now;
  }
  return outSplits.Length > 0;
}

#if DEPENDENCY_MLFEEDRACEDATA
void TrySyncPbFromPersonalBestGhost() {
  if (!S_UsePbGhostSync) return;
  auto gd = MLFeed::GetGhostData();
  if (gd is null || gd.Ghosts_V2 is null || gd.Ghosts_V2.Length == 0) return;

  const MLFeed::GhostInfo_V2@ pbGhost = null;
  for (uint i = 0; i < gd.Ghosts_V2.Length; i++) {
    auto g = gd.Ghosts_V2[i];
    if (g is null || !g.IsPersonalBest) continue;
    if (g.Result_Time <= 0 || g.Checkpoints.Length == 0) continue;
    if (pbGhost is null || g.Result_Time < pbGhost.Result_Time) @pbGhost = g;
  }
  if (pbGhost is null) return;

  array<int> splits;
  if (!BuildSplitsFromCumulative(pbGhost.Checkpoints, splits)) return;
  if (g_TotalCheckpoints > 0 && int(splits.Length) != g_TotalCheckpoints) return;

  bool changed = false;
  if (g_PbTime == 0 || pbGhost.Result_Time < g_PbTime || int(g_PbSplits.Length) != int(splits.Length)) {
    g_PbTime = pbGhost.Result_Time;
    g_PbSplits = splits;
    changed = true;
  }

  if (g_BestSplits.Length == 0 || int(g_BestSplits.Length) != int(splits.Length)) {
    g_BestSplits = splits;
    changed = true;
  } else {
    for (uint i = 0; i < g_BestSplits.Length && i < splits.Length; i++) {
      if (splits[i] < g_BestSplits[i]) {
        g_BestSplits[i] = splits[i];
        changed = true;
      }
    }
  }

  if (changed) SaveData();
}

void TryUpdateAutoWrFromGhosts() {
  auto gd = MLFeed::GetGhostData();
  if (gd is null || gd.Ghosts_V2 is null || gd.Ghosts_V2.Length == 0) return;

  const MLFeed::GhostInfo_V2@ bestWr = null;
  const MLFeed::GhostInfo_V2@ bestAny = null;
  for (uint i = 0; i < gd.Ghosts_V2.Length; i++) {
    auto g = gd.Ghosts_V2[i];
    if (g is null) continue;
    if (g.Result_Time <= 0 || g.Checkpoints.Length == 0) continue;
    // Ignore local PB ghost when no comparison ghost is loaded; prevents false "Live (You)" state.
    if (!g.IsPersonalBest && (bestAny is null || g.Result_Time < bestAny.Result_Time)) {
      @bestAny = g;
    }
    if (g.IsLocalPlayer || g.IsPersonalBest) continue;
    if (bestWr is null || g.Result_Time < bestWr.Result_Time) {
      @bestWr = g;
    }
  }
  const MLFeed::GhostInfo_V2@ wrCandidate = bestWr;
  if (wrCandidate is null) @wrCandidate = bestAny;
  if (wrCandidate is null) return;

  array<int> parsed;
  if (!BuildSplitsFromCumulative(wrCandidate.Checkpoints, parsed)) return;
  if (g_TotalCheckpoints > 0 && int(parsed.Length) != g_TotalCheckpoints) return;
  if (g_PbSplits.Length > 0 && int(parsed.Length) != int(g_PbSplits.Length)) return;
  g_LastWrLiveAt = Time::Now;

  string wrName = wrCandidate.Nickname;
  if (wrName.Length == 0 && wrCandidate.IsLocalPlayer) wrName = "Local Ghost";

  bool changed = g_WrGhostTime != wrCandidate.Result_Time
      || g_WrGhostName != wrName
      || g_WrSplitsAuto.Length != parsed.Length;
  if (!changed) {
    for (uint i = 0; i < parsed.Length; i++) {
      if (g_WrSplitsAuto[i] != parsed[i]) {
        changed = true;
        break;
      }
    }
  }
  if (!changed) return;

  g_WrSplitsAuto = parsed;
  g_WrGhostName = wrName;
  g_WrGhostTime = wrCandidate.Result_Time;
  SaveData();
}
#else
void TrySyncPbFromPersonalBestGhost() {}
void TryUpdateAutoWrFromGhosts() {}
#endif

bool TryMigrateLegacyData() {
  if (!S_AutoMigrateLegacy || g_MapUid.Length == 0 || g_LegacyMigratedThisMap) return false;
  if (g_PbTime > 0 || g_PbSplits.Length > 0 || g_BestSplits.Length > 0) return false;

  string mapFile = g_MapUid + ".json";
  array<string> candidates = {
    // BestCheckpointsTotal (Karlukki) common locations
    IO::FromAppFolder("PluginStorage/BestCheckpointsTotal/" + mapFile),
    IO::FromAppFolder("BestCheckpointsTotal/" + mapFile),
    IO::FromStorageFolder("../BestCheckpointsTotal/" + mapFile),

    // BestCheckpoints (other variants)
    IO::FromAppFolder("PluginStorage/BestCheckpoints/" + mapFile),
    IO::FromAppFolder("BestCheckpoints/" + mapFile),
    IO::FromStorageFolder("../BestCheckpoints/" + mapFile),

    // BestCP (legacy location used on this machine)
    IO::FromAppFolder("BestCP/" + mapFile),
    IO::FromStorageFolder("BestCP/" + mapFile),
    IO::FromDataFolder("../BestCP/" + mapFile)
  };

  string chosen = "";
  for (uint i = 0; i < candidates.Length; i++) {
    if (candidates[i].Length > 0 && IO::FileExists(candidates[i])) {
      chosen = candidates[i];
      break;
    }
  }
  if (chosen.Length == 0) return false;

  Json::Value legacy = Json::FromFile(chosen);
  if (legacy.GetType() != Json::Type::Object || !legacy.HasKey("size")) return false;
  int size = int(legacy["size"]);
  if (size <= 0) return false;

  array<int> splits;
  splits.Reserve(size);
  for (int i = 0; i < size; i++) {
    string k = "" + i;
    if (!legacy.HasKey(k)) return false;
    auto row = legacy[k];
    if (row.GetType() != Json::Type::Object) return false;
    int sp = row.HasKey("pbTime") ? int(row["pbTime"]) : int(row["time"]);
    if (sp <= 0) return false;
    splits.InsertLast(sp);
  }

  int pb = legacy.HasKey("pb") ? int(legacy["pb"]) : 0;
  if (pb <= 0) pb = SumRange(splits, 0, splits.Length);
  if (pb <= 0) return false;

  g_PbTime = pb;
  g_PbSplits = splits;
  g_BestSplits = splits;
  if (g_TotalCheckpoints <= 0) g_TotalCheckpoints = size;
  g_LegacyMigratedThisMap = true;
  SaveData();
  UI::ShowNotification("Checkpoint Pace", "Imported legacy checkpoint data for this map.");
  return true;
}

void LoadData() {
  string folder = IO::FromDataFolder("BestCheckpointsRedux");
  if (!IO::FolderExists(folder)) IO::CreateFolder(folder);
  g_DataFile = folder + "/" + g_MapUid + ".json";
  if (!IO::FileExists(g_DataFile)) return;

  Json::Value root = Json::FromFile(g_DataFile);
  if (root.GetType() != Json::Type::Object) return;

  if (root.HasKey("totalCheckpoints")) {
    int savedTotal = int(root["totalCheckpoints"]);
    if (savedTotal > 0) g_TotalCheckpoints = savedTotal;
  }

  if (root.HasKey("pbTime")) g_PbTime = int(root["pbTime"]);
  if (root.HasKey("bestSplits")) {
    auto best = root["bestSplits"];
    g_BestSplits.RemoveRange(0, g_BestSplits.Length);
    for (uint i = 0; i < best.Length; i++) g_BestSplits.InsertLast(int(best[i]));
  }
  if (root.HasKey("pbSplits")) {
    auto pb = root["pbSplits"];
    g_PbSplits.RemoveRange(0, g_PbSplits.Length);
    for (uint i = 0; i < pb.Length; i++) g_PbSplits.InsertLast(int(pb[i]));
  }
  if (root.HasKey("wrAutoSplits")) {
    auto wr = root["wrAutoSplits"];
    g_WrSplitsAuto.RemoveRange(0, g_WrSplitsAuto.Length);
    for (uint i = 0; i < wr.Length; i++) g_WrSplitsAuto.InsertLast(int(wr[i]));
  }
  if (root.HasKey("wrAutoGhost")) g_WrGhostName = string(root["wrAutoGhost"]);
  if (root.HasKey("wrAutoTime")) g_WrGhostTime = int(root["wrAutoTime"]);

  TryMigrateLegacyData();
}

void SaveData() {
  if (!S_SaveData || g_MapUid.Length == 0) return;
  string folder = IO::FromDataFolder("BestCheckpointsRedux");
  if (!IO::FolderExists(folder)) IO::CreateFolder(folder);
  if (g_DataFile.Length == 0) g_DataFile = folder + "/" + g_MapUid + ".json";

  Json::Value root = Json::Object();
  root["version"] = kDataVersion;
  root["mapUid"] = g_MapUid;
  root["totalCheckpoints"] = g_TotalCheckpoints;
  root["pbTime"] = g_PbTime;

  Json::Value best = Json::Array();
  for (uint i = 0; i < g_BestSplits.Length; i++) best.Add(g_BestSplits[i]);
  Json::Value pb = Json::Array();
  for (uint i = 0; i < g_PbSplits.Length; i++) pb.Add(g_PbSplits[i]);
  Json::Value wrAuto = Json::Array();
  for (uint i = 0; i < g_WrSplitsAuto.Length; i++) wrAuto.Add(g_WrSplitsAuto[i]);
  root["bestSplits"] = best;
  root["pbSplits"] = pb;
  root["wrAutoSplits"] = wrAuto;
  root["wrAutoGhost"] = g_WrGhostName;
  root["wrAutoTime"] = g_WrGhostTime;

  Json::ToFile(g_DataFile, root);
}

void Render() {
  if (!S_WindowVisible) return;
  if (S_HideWithGameUi && !UI::IsGameUIVisible()) return;
  if (S_AutoHideWhenNotDriving && !IsPlayerReady()) {
    if (!(S_ShowOnImproveScreen && ShouldShowWhenNotReady())) return;
  }
  if (g_MapUid.Length == 0) return;

  bool wrFeatureReady = S_ShowWR && HasWrDeps() && IsWrFeatureAvailable();
  const array<int>@ wrRef = GetActiveWrSplitsRef();
  bool wrShow = wrFeatureReady && wrRef.Length > 0;
  int cols = 4;
  if (wrShow) cols += 2;
  if (S_ShowSpeed) cols++;
  if (S_ShowCumulative) cols++;
  int rows = Math::Max(6, S_MaxRows);

  if (S_LockWindowPos) UI::SetNextWindowPos(int(S_WindowPos.x), int(S_WindowPos.y), UI::Cond::Always);
  else UI::SetNextWindowPos(int(S_WindowPos.x), int(S_WindowPos.y), UI::Cond::FirstUseEver);

  int flags = UI::WindowFlags::NoCollapse | UI::WindowFlags::AlwaysAutoResize;
  if (!UI::IsOverlayShown()) flags |= UI::WindowFlags::NoInputs;

  vec4 bg = vec4(0.08f, 0.10f, 0.14f, 0.95f);
  if (S_FlashOnPb && Time::Now < g_PbFlashUntil) bg = vec4(0.07f, 0.18f, 0.12f, 0.97f);
  UI::PushStyleColor(UI::Col::WindowBg, bg);
  UI::PushStyleColor(UI::Col::Header, vec4(0.15f, 0.20f, 0.27f, 1.0f));
  UI::PushStyleColor(UI::Col::HeaderHovered, vec4(0.20f, 0.26f, 0.35f, 1.0f));
  UI::PushStyleColor(UI::Col::TitleBg, vec4(0.10f, 0.14f, 0.20f, 1.0f));
  UI::PushStyleColor(UI::Col::TitleBgActive, vec4(0.10f, 0.14f, 0.20f, 1.0f));
  UI::PushStyleColor(UI::Col::Border, vec4(0.28f, 0.36f, 0.48f, 0.85f));
  UI::PushStyleVar(UI::StyleVar::WindowRounding, 8.0f);
  UI::PushStyleVar(UI::StyleVar::FrameRounding, 6.0f);
  UI::PushStyleVar(UI::StyleVar::WindowBorderSize, 1.0f);

  if (UI::Begin("Checkpoint Pace###BestCheckpointsRedux", flags)) {
    if (!S_LockWindowPos) S_WindowPos = UI::GetWindowPos();

    int theo = GetTheoreticalBest();
    int est = GetEstimatedFinish();
    int delta = GetCurrentVsBestDelta();
    int wrTotal = GetWrTotal();
    int wrDelta = GetCurrentVsWrDelta();
    int bestVsWr = GetBestVsWrDelta();
    float progress = g_TotalCheckpoints > 0 ? float(g_CheckpointsThisRun) / float(g_TotalCheckpoints) : 0.0f;

    UI::Text("CP " + g_CheckpointsThisRun + "/" + g_TotalCheckpoints);
    UI::SameLine();
    UI::TextDisabled("| PB " + (g_PbTime > 0 ? Time::Format(g_PbTime) : "--:--.---"));
    if (S_ShowWR) {
      UI::SameLine();
      string wrState = GetWrSourceLabel();
      if (wrState.StartsWith("Live")) UI::PushStyleColor(UI::Col::Text, vec4(0.38f, 0.95f, 0.56f, 1.0f));
      else if (wrState == "Cached") UI::PushStyleColor(UI::Col::Text, vec4(0.95f, 0.85f, 0.35f, 1.0f));
      else UI::PushStyleColor(UI::Col::Text, vec4(1.0f, 0.55f, 0.20f, 1.0f));
      UI::Text("| Ghost: " + wrState);
      UI::PopStyleColor();
    }
    UI::ProgressBar(progress, vec2(300, 5), "");

    UI::Separator();
    UI::Text("Theoretical  " + (theo > 0 ? Time::Format(theo) : "--:--.---"));
    UI::Text("Estimated    " + (est > 0 ? Time::Format(est) : "--:--.---"));
    if (wrShow && wrTotal > 0) {
      UI::Text("Ghost Total  " + Time::Format(wrTotal) + " [" + GetWrSourceLabel() + "]");
      UI::SameLine();
      DrawDeltaInline(wrDelta);
      UI::Text("Best vs Ghost");
      UI::SameLine();
      DrawDeltaCell(bestVsWr);
    } else if (S_ShowWR && (!HasWrDeps() || !IsWrFeatureAvailable())) {
      UI::PushStyleColor(UI::Col::Text, vec4(1.0f, 0.55f, 0.20f, 1.0f));
      UI::Text("Ghost mode unavailable: install/enable MLFeedRaceData + MLHook");
      UI::PopStyleColor();
    } else if (S_ShowWR && wrFeatureReady && wrRef.Length == 0) {
      UI::PushStyleColor(UI::Col::Text, vec4(0.95f, 0.85f, 0.35f, 1.0f));
      UI::Text("No ghost data yet: load/show a ghost once to cache splits.");
      UI::PopStyleColor();
    }
    UI::Separator();

    if (UI::BeginTable("bcx_table", cols, UI::TableFlags::SizingFixedFit)) {
      UI::TableNextColumn(); UI::Text("CP");
      UI::TableNextColumn(); UI::Text("Split");
      UI::TableNextColumn(); UI::Text("Best");
      UI::TableNextColumn(); UI::Text("Delta");
      if (wrShow) { UI::TableNextColumn(); UI::Text("Ghost"); }
      if (wrShow) { UI::TableNextColumn(); UI::Text("Ghost Delta"); }
      if (S_ShowSpeed) { UI::TableNextColumn(); UI::Text("Speed"); }
      if (S_ShowCumulative) { UI::TableNextColumn(); UI::Text("Cum"); }

      int currentRow = int(g_CurrentSplits.Length) - 1;
      int start = 0;
      if (currentRow > rows / 2) start = currentRow - rows / 2;
      int totalRows = int(Math::Max(g_CurrentSplits.Length, g_BestSplits.Length));
      if (wrShow) totalRows = int(Math::Max(totalRows, GetWrSplitCount()));
      int end = Math::Min(start + rows, totalRows);

      for (int i = start; i < end; i++) {
        UI::TableNextRow();
        bool isCurrent = i == currentRow;
        if (isCurrent) UI::PushStyleColor(UI::Col::Text, vec4(0.75f, 0.86f, 1.0f, 1.0f));

        UI::TableNextColumn();
        UI::Text(GetCheckpointLabel(i));

        UI::TableNextColumn();
        if (i < int(g_CurrentSplits.Length)) UI::Text(Time::Format(g_CurrentSplits[i]));
        else UI::TextDisabled("-");

        UI::TableNextColumn();
        if (i < int(g_BestSplits.Length)) UI::Text(Time::Format(g_BestSplits[i]));
        else UI::TextDisabled("-");

        UI::TableNextColumn();
        int bestForDelta = GetBestSplitForDeltaAt(i);
        if (i < int(g_CurrentSplits.Length) && bestForDelta > 0) {
          bool isFinishRow = (g_TotalCheckpoints > 0 && i == g_TotalCheckpoints - 1)
              || (g_RunFinished && i == int(g_CurrentSplits.Length) - 1);
          if (isFinishRow && g_RunFinished && i == int(g_CurrentSplits.Length) - 1 && g_HasLastFinishDeltaVsPb) {
            DrawDeltaCell(g_LastFinishDeltaVsPb);
          } else if (isFinishRow && i < int(g_CurrentCumulative.Length) && i < int(g_PbSplits.Length)) {
            int pbCum = GetPbCumulativeAt(uint(i));
            if (pbCum > 0) DrawDeltaCell(g_CurrentCumulative[i] - pbCum);
            else DrawDeltaCell(g_CurrentSplits[i] - bestForDelta);
          } else {
            DrawDeltaCell(g_CurrentSplits[i] - bestForDelta);
          }
        } else {
          UI::TextDisabled("-");
        }

        if (wrShow) {
          UI::TableNextColumn();
          if (i < int(wrRef.Length)) UI::Text(Time::Format(wrRef[i]));
          else UI::TextDisabled("-");
        }
        if (wrShow) {
          UI::TableNextColumn();
          if (i < int(g_CurrentSplits.Length) && i < int(wrRef.Length)) {
            DrawDeltaCell(g_CurrentSplits[i] - wrRef[i]);
          } else {
            UI::TextDisabled("-");
          }
        }

        if (S_ShowSpeed) {
          UI::TableNextColumn();
          if (i < int(g_CurrentSpeeds.Length) && g_CurrentSpeeds[i] >= 0) UI::Text("" + g_CurrentSpeeds[i]);
          else UI::TextDisabled("-");
        }

        if (S_ShowCumulative) {
          UI::TableNextColumn();
          if (i < int(g_CurrentCumulative.Length)) UI::Text(Time::Format(g_CurrentCumulative[i]));
          else UI::TextDisabled("-");
        }

        if (isCurrent) UI::PopStyleColor();
      }
      UI::EndTable();
    }
  }
  UI::End();

  UI::PopStyleVar(3);
  UI::PopStyleColor(6);
}

void DrawDeltaInline(int delta) {
  UI::SameLine();
  DrawDeltaCell(delta);
}

void DrawDeltaCell(int delta) {
  if (delta > 0) {
    UI::PushStyleColor(UI::Col::Text, vec4(1.0f, 0.35f, 0.35f, 1.0f));
    UI::Text("+" + Time::Format(delta));
  } else if (delta < 0) {
    UI::PushStyleColor(UI::Col::Text, vec4(0.38f, 0.95f, 0.56f, 1.0f));
    UI::Text("-" + Time::Format(-delta));
  } else {
    UI::PushStyleColor(UI::Col::Text, vec4(0.75f, 0.75f, 0.75f, 1.0f));
    UI::Text("+0.000");
  }
  UI::PopStyleColor();
}

bool ShouldShowWhenNotReady() {
  // keep visible briefly after finish or while run data is still on screen
  if (g_RunFinished || g_CurrentSplits.Length > 0) return true;

  // If we can still read a race timer context, we're likely in countdown/improve
  // and should keep the panel visible.
  int raceTime = GetCurrentPlayerRaceTimeMs();
  if (raceTime != -1) return true;

  return false;
}

