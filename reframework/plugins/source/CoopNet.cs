// CoopNet.cs: RE7 co-op transport (REFramework C# source plugin).
//
// Moves player state, events and enemy snapshots between two game instances. It
// touches no game API: the Lua scripts write what to send into reframework/data
// files and read what arrived from others (coopnet_out/in, coopnet_ev_out/in,
// coopnet_es_out/in), plus coopnet_command.txt for UI commands, coopnet_status.txt
// and coopnet_friends.txt for the window. It also makes the save backups.
//
// Modes (reframework/data/coopnet_config.json):
//   "echo":  send to our own socket on 127.0.0.1, so the ghost replays us
//            through the full network path. One PC, no firewall prompt.
//   "udp":   send to peerHost:peerPort. Needs a reachable port.
//   "steam": send to peerSteamId over Valve's relay (ISteamNetworkingMessages,
//            P/Invoked from the game's own steam_api64.dll). No port forwarding.
//   "bot":   a simulated friend (follow me / circle / stay) through the normal
//            receive path, with latency, jitter and loss. For testing alone.
//
// Packets:
//   "R7C2" player state, 64 bytes, little endian, ~30 a second, unreliable:
//     u32 seq | f64 senderTime | f32 px py pz | f32 qx qy qz qw
//     | u32 stance flags | u32 chapter | f32 ping echo | f32 lookYaw lookPitch
//   "R7E1" + UTF-8 text: one-off events (kills, doors, pickups, cutscenes, down/up),
//     reliable; coopnet_ev_out.txt / coopnet_ev_in.txt.
//   "R7S1" + UTF-8 text: enemy snapshots, ~10 a second, unreliable, newest wins;
//     coopnet_es_out.txt / coopnet_es_in.txt.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using REFrameworkNET;
using REFrameworkNET.Attributes;

public class CoopNet
{
    class Config
    {
        public string mode { get; set; } = "echo";
        public string bindHost { get; set; } = "127.0.0.1";
        public int localPort { get; set; } = 27777;
        public string peerHost { get; set; } = "127.0.0.1";
        public int peerPort { get; set; } = 27777;
        public int sendHz { get; set; } = 30;
        public string peerSteamId { get; set; } = "";   // friend's SteamID64, "steam" mode
        public int steamChannel { get; set; } = 7;
        // "bot" mode: a fake remote player walking a circle around where we stand,
        // delivered through the normal receive path with simulated network trouble.
        public double botRadius { get; set; } = 3.0;
        public double botSpeed { get; set; } = 1.3;      // m/s
        public double botPauseEvery { get; set; } = 8.0; // s of walking, then a pause
        public double botPauseFor { get; set; } = 2.5;   // s standing still
        public double botYawOffsetDeg { get; set; } = 0.0;
        // Cycle the bot's facing every botDirEvery s: forward, 90, 180, 270 degrees
        // off its direction of travel, to exercise strafe and backpedal clips.
        public bool botDirCycle { get; set; } = true;
        public double botDirEvery { get; set; } = 4.0;
        // Cycle stance every botStanceEvery s (walk, jog, crouch), sending the same
        // stance flags a real player's PlayerMovement produces.
        public bool botStanceCycle { get; set; } = true;
        public double botStanceEvery { get; set; } = 16.0;
        public double botTurnRateDeg { get; set; } = 240;   // facing changes turn, not snap
        public int botChapter { get; set; } = -1;            // -1: same chapter as us; else fake "other chapter"
        // "follow": the bot walks the path we walked, a few seconds behind, and waits
        // near us (stays on real ground). "circle": the old fixed circle with stance and
        // direction cycling, for checking every walking clip.
        public string botMode { get; set; } = "follow";
        public double botFollowDist { get; set; } = 2.5;     // m: stop this close to us
        public int saveBackupsKeep { get; set; } = 20;
        public double botJogSpeed { get; set; } = 3.4;
        public double botCrouchSpeed { get; set; } = 0.9;
        public double simLatencyMs { get; set; } = 80;
        public double simJitterMs { get; set; } = 30;
        public double simLossPct { get; set; } = 5;
    }

    // Fake remote player ----------------------------------------------------------

    static class Bot
    {
        static bool s_haveCenter;
        static float s_cx, s_cy, s_cz;
        static double s_angle, s_walked, s_facing;
        static bool s_paused;
        static double s_pauseLeft;
        static uint s_seq;
        static readonly Stopwatch s_clock = Stopwatch.StartNew();
        static double s_last;
        static readonly Random s_rng = new Random();
        static readonly List<(double due, byte[] pkt)> s_inFlight = new List<(double, byte[])>();
        public static string Expect = "-";
        public static Sample LastLocal;   // newest local sample, so the bot can echo it like a real peer

        static int Stance(Config c, double now) =>
            c.botStanceCycle ? (int)(now / Math.Max(1, c.botStanceEvery)) % 3 : 0;

        static double StanceSpeed(Config c, double now) => Stance(c, now) switch
        {
            1 => c.botJogSpeed,
            2 => c.botCrouchSpeed,
            _ => c.botSpeed,
        };

        // The bot circles where we stand. Re-centre when we change chapter or end up far
        // from the circle (load, chapter jump, teleport); otherwise it kept circling the
        // old chapter's coordinates, outside the new map.
        static uint s_centerChapter;
        public static void Recenter() => s_haveCenter = false;

        public static void SetCenter(Sample local)
        {
            if (s_haveCenter)
            {
                double dx = local.Px - s_cx, dz = local.Pz - s_cz;
                bool far = Math.Sqrt(dx * dx + dz * dz) > 30.0 || Math.Abs(local.Py - s_cy) > 10.0;
                if ((local.Id & 0xFF) == s_centerChapter && !far) return;
                API.LogInfo($"[CoopNet] bot re-centred ({(far ? "player moved far" : "chapter changed")})");
            }
            s_cx = local.Px; s_cy = local.Py; s_cz = local.Pz;
            s_centerChapter = local.Id & 0xFF;
            s_haveCenter = true;
        }

        // Follow mode ---------------------------------------------------------------
        // Our own samples are a trail of real ground with real stance, facing and look,
        // timed by when we were there (the sample's own game-clock time: the IO thread
        // picks samples up unevenly, and timing by that made the replay stutter). The bot
        // replays it from a playhead that runs at normal speed (1.25x when far behind),
        // stops when the replayed spot gets within botFollowDist of us and only moves on
        // once it's a metre further (no stop-go flicker at the edge); then it stands and
        // turns to face us.
        static readonly List<(double t, Sample s)> s_trail = new List<(double, Sample)>();
        static double s_head = -1;
        static float s_fyaw;
        static bool s_haveFollow, s_waiting;

        public static void Record(Sample local)
        {
            double now = local.T;
            if (s_trail.Count > 0)
            {
                var last = s_trail[s_trail.Count - 1].s;
                double jump = Dist(last, local.Px, local.Py, local.Pz);
                if (jump > 10 || (local.Id & 0xFF) != (last.Id & 0xFF) || local.T < s_trail[s_trail.Count - 1].t)
                {
                    // Load, chapter jump or teleport: the old trail leads nowhere now.
                    s_trail.Clear();
                    s_head = -1;
                    s_haveFollow = false;   // hidden again until we walk away from the new spot
                    API.LogInfo("[CoopNet] bot trail reset (" + (jump > 10 ? "player moved far" : "chapter changed") + ")");
                }
            }
            s_trail.Add((now, local));
            if (s_head < 0) s_head = now;
            // Keep at most a minute behind the newest point.
            if (now - s_head > 60) s_head = now - 60;
            while (s_trail.Count > 2 && s_trail[1].t < s_head - 1) s_trail.RemoveAt(0);
        }

        static double Dist(Sample a, float x, float y, float z)
        {
            double dx = a.Px - x, dy = a.Py - y, dz = a.Pz - z;
            return Math.Sqrt(dx * dx + dy * dy + dz * dz);
        }

        static Sample TrailAt(double t)
        {
            for (int i = s_trail.Count - 1; i > 0; i--)
            {
                if (s_trail[i - 1].t <= t)
                {
                    var (t0, a) = s_trail[i - 1];
                    var (t1, b) = s_trail[i];
                    double k = t1 > t0 ? Math.Clamp((t - t0) / (t1 - t0), 0, 1) : 1;
                    var s = a;
                    s.Px = (float)(a.Px + (b.Px - a.Px) * k);
                    s.Py = (float)(a.Py + (b.Py - a.Py) * k);
                    s.Pz = (float)(a.Pz + (b.Pz - a.Pz) * k);
                    if (k > 0.5) { s.Qx = b.Qx; s.Qy = b.Qy; s.Qz = b.Qz; s.Qw = b.Qw; s.Bank = b.Bank; s.LookYaw = b.LookYaw; s.LookPitch = b.LookPitch; }
                    return s;
                }
            }
            return s_trail[0].s;
        }

        // Returns false while there is nothing to follow yet.
        static bool FollowStep(Config c, double now, double dt, ref Sample s)
        {
            if (s_trail.Count == 0) return false;
            var me = s_trail[s_trail.Count - 1].s;
            var at = TrailAt(s_head);
            double behind = Dist(at, me.Px, me.Py, me.Pz);
            // A new trail starts where we stand: stay hidden (send nothing) until we've
            // walked away, so the bot doesn't appear inside us.
            if (!s_haveFollow && behind < c.botFollowDist) { Expect = "appears once you walk away"; return false; }
            double rate = behind > 8 ? 1.25 : 1.0;
            double endT = s_trail[s_trail.Count - 1].t;
            double nextHead = Math.Min(s_head + dt * rate, endT);
            var next = TrailAt(nextHead);
            // Skip the stretches where we stood still: replaying them made the bot stand
            // around metres away instead of coming over.
            // Fine steps that stop as soon as the trail moves again: 0.1 s steps with a 2 cm
            // test caused 52 visible jumps in 75 s (it also fired on slow walking).
            for (int i = 0; i < 6000 && nextHead < endT && Dist(next, at.Px, at.Py, at.Pz) < 0.003; i++)
            {
                nextHead = Math.Min(nextHead + 0.01, endT);
                next = TrailAt(nextHead);
            }
            double gap = Dist(next, me.Px, me.Py, me.Pz);
            s_waiting = s_waiting ? gap < c.botFollowDist + 1.0 : gap < c.botFollowDist;
            bool waiting = s_waiting;
            if (!waiting) { s_head = nextHead; at = next; }

            s.Px = at.Px; s.Py = at.Py; s.Pz = at.Pz;
            if (waiting)
            {
                // Stand and turn to face us; crouch if we were crouching there.
                double want = Math.Atan2(me.Px - at.Px, me.Pz - at.Pz);
                if (!s_haveFollow) s_fyaw = (float)want;
                double diff = Math.IEEERemainder(want - s_fyaw, 2 * Math.PI);
                double step = c.botTurnRateDeg * Math.PI / 180 * dt;
                s_fyaw += (float)(Math.Abs(diff) <= step ? diff : Math.Sign(diff) * step);
                s.Qx = 0; s.Qy = (float)Math.Sin(s_fyaw / 2); s.Qz = 0; s.Qw = (float)Math.Cos(s_fyaw / 2);
                s.Bank = 4u | (at.Bank & 1u) | (LastLocal.Bank & 0xFFFFF000u);   // + our second action, live like Id
                s.LookYaw = 0; s.LookPitch = 0;
                Expect = (at.Bank & 1u) != 0 ? "waiting near you, crouched" : "waiting near you";
            }
            else
            {
                // Replay our facing, stance and look on that stretch.
                s.Qx = at.Qx; s.Qy = at.Qy; s.Qz = at.Qz; s.Qw = at.Qw;
                s.Bank = (at.Bank & 3u) | 4u | (LastLocal.Bank & 0xFFFFF000u);   // our stance, never our cutscene bit (it hid the bot); our second action
                s.LookYaw = at.LookYaw; s.LookPitch = at.LookPitch;
                s_fyaw = (float)(2 * Math.Atan2(at.Qy, at.Qw));
                Expect = "following you (" + ((at.Bank & 1u) != 0 ? "crouch" : (at.Bank & 2u) != 0 ? "walk" : "jog") +
                         (rate > 1 ? ", catching up" : "") + ")";
            }
            s_haveFollow = true;
            return true;
        }

        // Advance the bot, "send" a packet into the simulated network, and deliver
        // whatever has finished its simulated trip.
        public static void Tick(Config c, Action<byte[]> deliver)
        {
            double now = s_clock.Elapsed.TotalSeconds;
            double dt = s_last == 0 ? 0 : now - s_last;
            s_last = now;

            if (c.botMode == "stay" && s_haveFollow)
            {
                // Stand where we are (testing: lets us walk away from the bot).
                var st = new Sample { Seq = ++s_seq, T = now };
                var at = s_trail.Count > 0 ? TrailAt(s_head) : LastLocal;
                st.Px = at.Px; st.Py = at.Py; st.Pz = at.Pz;
                st.Qx = 0; st.Qy = (float)Math.Sin(s_fyaw / 2); st.Qz = 0; st.Qw = (float)Math.Cos(s_fyaw / 2);
                st.Bank = 4u;
                st.Id = c.botChapter >= 0 ? (LastLocal.Id & ~0xFFu) | (uint)c.botChapter : LastLocal.Id;
                st.Frame = (float)(LastLocal.T % 1000.0);
                Expect = "staying here";
                Transmit(c, now, st);
                DeliverDue(now, deliver);
                return;
            }
            if (c.botMode == "follow" || c.botMode == "stay")
            {
                var f = new Sample { Seq = ++s_seq, T = now };
                if (FollowStep(c, now, dt, ref f))
                {
                    f.Id = c.botChapter >= 0 ? (LastLocal.Id & ~0xFFu) | (uint)c.botChapter : LastLocal.Id;
                    f.Frame = (float)(LastLocal.T % 1000.0);
                    Transmit(c, now, f);
                }
                DeliverDue(now, deliver);
                return;
            }
            if (!s_haveCenter) return;

            if (s_paused)
            {
                s_pauseLeft -= dt;
                if (s_pauseLeft <= 0) { s_paused = false; s_walked = 0; }
            }
            else
            {
                s_angle += StanceSpeed(c, now) * dt / Math.Max(0.5, c.botRadius);
                s_walked += dt;
                if (c.botPauseEvery > 0 && s_walked >= c.botPauseEvery) { s_paused = true; s_pauseLeft = c.botPauseFor; }
            }

            var s = new Sample { Seq = ++s_seq, T = now };
            s.Px = (float)(s_cx + c.botRadius * Math.Sin(s_angle));
            s.Py = s_cy;
            s.Pz = (float)(s_cz + c.botRadius * Math.Cos(s_angle));
            // Face along the circle (tangent), plus a configurable offset in case the
            // engine's forward axis differs.
            int phase = c.botDirCycle ? (int)(now / Math.Max(1, c.botDirEvery)) % 4 : 0;
            // Facing = travel + phase*90 deg, so travel relative to facing is -phase*90.
            // With +Z forward and right = local -X (Lua's convention), +90 means
            // moving to the bot's right.
            int stance = Stance(c, now);   // 0 walk, 1 jog, 2 crouch
            var stanceName = new[] { "walk", "jog", "crouch" }[stance];
            Expect = s_paused ? (stance == 2 ? "crouch, standing" : "standing")
                              : stanceName + " " + new[] { "fwd", "right", "back", "left" }[phase];
            // Turn toward the phase's facing offset at botTurnRateDeg, shortest way round.
            double target = phase * Math.PI / 2;
            double diff = Math.IEEERemainder(target - s_facing, 2 * Math.PI);
            double step = c.botTurnRateDeg * Math.PI / 180 * dt;
            s_facing += Math.Abs(diff) <= step ? diff : Math.Sign(diff) * step;
            double yaw = s_angle + Math.PI / 2 + s_facing + c.botYawOffsetDeg * Math.PI / 180;
            s.Qx = 0; s.Qy = (float)Math.Sin(yaw / 2); s.Qz = 0; s.Qw = (float)Math.Cos(yaw / 2);
            // Same flags as Lua's local_stance_flags: bit0 crouch, bit1 walking, bit2 valid.
            s.Bank = 4u | (stance == 2 ? 1u : 0u) | (stance == 0 ? 2u : 0u);
            // Chapter (same as ours unless faked) and the ping echo: like a real peer,
            // send back the newest sender time we've seen from the other side, mod 1000 s.
            s.Id = c.botChapter >= 0 ? (LastLocal.Id & ~0xFFu) | (uint)c.botChapter : LastLocal.Id;
            s.Frame = (float)(LastLocal.T % 1000.0);
            // Look around like a player: slow sweep left/right, gentle up/down.
            s.LookYaw = (float)(0.9 * Math.Sin(now * 0.7));
            s.LookPitch = (float)(0.35 * Math.Sin(now * 0.45));

            Transmit(c, now, s);
            DeliverDue(now, deliver);
        }

        // Into the simulated network: latency, jitter and loss like a real connection.
        static void Transmit(Config c, double now, Sample s)
        {
            if (s_rng.NextDouble() * 100 >= c.simLossPct)
            {
                double delay = (c.simLatencyMs + (s_rng.NextDouble() * 2 - 1) * c.simJitterMs) / 1000.0;
                s_inFlight.Add((now + Math.Max(0, delay), Encode(s)));
            }
        }

        static void DeliverDue(double now, Action<byte[]> deliver)
        {
            for (int i = s_inFlight.Count - 1; i >= 0; i--)
            {
                if (s_inFlight[i].due <= now) { deliver(s_inFlight[i].pkt); s_inFlight.RemoveAt(i); }
            }
        }

        // An event "from the friend" (testing), delivered after the usual latency, never lost.
        public static void QueueEvent(Config c, string text)
        {
            double now = s_clock.Elapsed.TotalSeconds;
            s_inFlight.Add((now + c.simLatencyMs / 1000.0, EncodeEvent(text)));
        }
    }

    // Steam transport (flat API of the game's steam_api64.dll) --------------------
    // The game has already initialised Steam; the accessors return its interfaces.

    static class Steam
    {
        const string Dll = "steam_api64";
        const int IdentitySize = 136;        // SteamNetworkingIdentity
        const int SendUnreliableNoNagle = 1; // k_nSteamNetworkingSend_UnreliableNoNagle
        const int SendFlagReliable = 8;      // k_nSteamNetworkingSend_Reliable
        const int SendAutoRestart = 32;      // k_nSteamNetworkingSend_AutoRestartBrokenSession

        [DllImport(Dll)] static extern IntPtr SteamAPI_SteamNetworkingMessages_SteamAPI_v002();
        [DllImport(Dll)] static extern IntPtr SteamAPI_SteamNetworkingUtils_SteamAPI_v003();
        [DllImport(Dll)] static extern IntPtr SteamAPI_SteamUser_v021();
        [DllImport(Dll)] static extern IntPtr SteamAPI_SteamFriends_v017();
        [DllImport(Dll)] static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr self);
        [DllImport(Dll)] static extern IntPtr SteamAPI_ISteamFriends_GetPersonaName(IntPtr self);
        [DllImport(Dll)] static extern IntPtr SteamAPI_ISteamFriends_GetFriendPersonaName(IntPtr self, ulong steamId);
        [DllImport(Dll)] static extern void SteamAPI_ISteamFriends_RequestUserInformation(IntPtr self, ulong steamId,
            [MarshalAs(UnmanagedType.I1)] bool requireNameOnly);
        [DllImport(Dll)] [return: MarshalAs(UnmanagedType.I1)]
        static extern bool SteamAPI_ISteamUser_GetUserDataFolder(IntPtr self, byte[] buffer, int bufferSize);
        [DllImport(Dll)] static extern void SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(IntPtr self);
        [DllImport(Dll)] static extern int SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus(IntPtr self, IntPtr details);
        [DllImport(Dll)] static extern void SteamAPI_SteamNetworkingIdentity_Clear(IntPtr self);
        [DllImport(Dll)] static extern void SteamAPI_SteamNetworkingIdentity_SetSteamID64(IntPtr self, ulong id);
        [DllImport(Dll)] static extern ulong SteamAPI_SteamNetworkingIdentity_GetSteamID64(IntPtr self);
        [DllImport(Dll)] static extern int SteamAPI_ISteamNetworkingMessages_SendMessageToUser(
            IntPtr self, IntPtr identity, byte[] data, uint size, int flags, int channel);
        [DllImport(Dll)] static extern int SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(
            IntPtr self, int channel, [Out] IntPtr[] messages, int max);
        [DllImport(Dll)] [return: MarshalAs(UnmanagedType.I1)]
        static extern bool SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(IntPtr self, IntPtr identity);
        [DllImport(Dll)] static extern void SteamAPI_SteamNetworkingMessage_t_Release(IntPtr msg);
        [DllImport(Dll)] static extern int SteamAPI_ISteamFriends_GetFriendCount(IntPtr self, int flags);
        [DllImport(Dll)] static extern ulong SteamAPI_ISteamFriends_GetFriendByIndex(IntPtr self, int index, int flags);
        [DllImport(Dll)] static extern int SteamAPI_ISteamFriends_GetFriendPersonaState(IntPtr self, ulong steamId);
        [DllImport(Dll)] [return: MarshalAs(UnmanagedType.I1)]
        static extern bool SteamAPI_ISteamFriends_GetFriendGamePlayed(IntPtr self, ulong steamId, IntPtr info);
        [DllImport(Dll)] [return: MarshalAs(UnmanagedType.I1)]
        static extern bool SteamAPI_ISteamFriends_SetRichPresence(IntPtr self, byte[] key, byte[] value);
        [DllImport(Dll)] static extern IntPtr SteamAPI_ISteamFriends_GetFriendRichPresence(IntPtr self, ulong steamId, byte[] key);
        [DllImport(Dll)] static extern void SteamAPI_ISteamFriends_RequestFriendRichPresence(IntPtr self, ulong steamId);

        const int FriendFlagImmediate = 4;   // k_EFriendFlagImmediate: regular friends
        const uint Re7AppId = 418370;

        static IntPtr s_msgs, s_utils, s_peerIdentity, s_friends, s_user, s_gameInfo;
        static ulong s_peerId;
        static int s_channel;
        static readonly IntPtr[] s_inbox = new IntPtr[32];
        public static ulong SelfId;
        public static string SelfName = "?";
        public static int LastSendResult;

        public static void Init(int channel)
        {
            s_msgs = SteamAPI_SteamNetworkingMessages_SteamAPI_v002();
            s_utils = SteamAPI_SteamNetworkingUtils_SteamAPI_v003();
            var user = SteamAPI_SteamUser_v021();
            var friends = SteamAPI_SteamFriends_v017();
            if (s_msgs == IntPtr.Zero || s_utils == IntPtr.Zero || user == IntPtr.Zero)
                throw new InvalidOperationException("Steam interfaces unavailable (is Steam running?)");
            SelfId = SteamAPI_ISteamUser_GetSteamID(user);
            (s_friends, s_user) = (friends, user);
            if (friends != IntPtr.Zero) SelfName = Marshal.PtrToStringUTF8(SteamAPI_ISteamFriends_GetPersonaName(friends)) ?? "?";
            SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(s_utils);

            s_channel = channel;
            s_peerIdentity = Marshal.AllocHGlobal(IdentitySize);
            SteamAPI_SteamNetworkingIdentity_Clear(s_peerIdentity);
        }

        // Friend's Steam name for the nameplate; Steam may need a moment to fetch it.
        public static string PeerName()
        {
            if (s_friends == IntPtr.Zero || s_peerId == 0) return "";
            var name = Marshal.PtrToStringUTF8(SteamAPI_ISteamFriends_GetFriendPersonaName(s_friends, s_peerId)) ?? "";
            return name == "[unknown]" ? "" : name;
        }

        static byte[] Utf8z(string s) => Encoding.UTF8.GetBytes((s ?? "") + "\0");

        // Rich presence is shared automatically with friends in the same game, which
        // makes it a callback-free way to say "co-op is running" and "I'm inviting you".
        public static void SetPresence(string key, string value)
        {
            if (s_friends != IntPtr.Zero) SteamAPI_ISteamFriends_SetRichPresence(s_friends, Utf8z(key), Utf8z(value));
        }

        static string Presence(ulong id, string key) =>
            Marshal.PtrToStringUTF8(SteamAPI_ISteamFriends_GetFriendRichPresence(s_friends, id, Utf8z(key))) ?? "";

        public struct Friend { public ulong Id; public string Name, CoopVersion; public bool InRe7, InvitesMe; }

        static readonly HashSet<ulong> s_presenceAsked = new HashSet<ulong>();

        // Online friends, with whether they're in RE7, running co-op, or inviting us.
        public static List<Friend> Friends()
        {
            var list = new List<Friend>();
            if (s_friends == IntPtr.Zero) return list;
            if (s_gameInfo == IntPtr.Zero) s_gameInfo = Marshal.AllocHGlobal(64);   // FriendGameInfo_t (24 bytes)
            int n = SteamAPI_ISteamFriends_GetFriendCount(s_friends, FriendFlagImmediate);
            for (int i = 0; i < n; i++)
            {
                var id = SteamAPI_ISteamFriends_GetFriendByIndex(s_friends, i, FriendFlagImmediate);
                if (id == 0 || SteamAPI_ISteamFriends_GetFriendPersonaState(s_friends, id) == 0) continue;   // offline
                // FriendGameInfo_t starts with the CGameID; its low 24 bits are the app id.
                bool inRe7 = SteamAPI_ISteamFriends_GetFriendGamePlayed(s_friends, id, s_gameInfo) &&
                             ((ulong)Marshal.ReadInt64(s_gameInfo) & 0xFFFFFF) == Re7AppId;
                var f = new Friend { Id = id, InRe7 = inRe7, CoopVersion = "", Name =
                    Marshal.PtrToStringUTF8(SteamAPI_ISteamFriends_GetFriendPersonaName(s_friends, id)) ?? "?" };
                if (inRe7)
                {
                    if (s_presenceAsked.Add(id)) SteamAPI_ISteamFriends_RequestFriendRichPresence(s_friends, id);
                    f.CoopVersion = Presence(id, "coop_re7");
                    f.InvitesMe = Presence(id, "coop_re7_to") == SelfId.ToString(Inv);
                }
                list.Add(f);
            }
            return list;
        }

        // ...\Steam\userdata\<id>\418370\local; the game's saves sit in the sibling "remote".
        public static string UserDataFolder()
        {
            if (s_user == IntPtr.Zero) return null;
            var buf = new byte[1024];
            if (!SteamAPI_ISteamUser_GetUserDataFolder(s_user, buf, buf.Length)) return null;
            int n = Array.IndexOf(buf, (byte)0);
            return Encoding.UTF8.GetString(buf, 0, n < 0 ? buf.Length : n);
        }

        public static void SetPeer(ulong peer)
        {
            SteamAPI_SteamNetworkingIdentity_Clear(s_peerIdentity);
            s_peerId = peer;
            if (peer == 0) return;
            if (s_friends != IntPtr.Zero) SteamAPI_ISteamFriends_RequestUserInformation(s_friends, peer, true);
            SteamAPI_SteamNetworkingIdentity_SetSteamID64(s_peerIdentity, peer);
            SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser(s_msgs, s_peerIdentity);
        }

        // ESteamNetworkingAvailability: 100 = Current, 3 = Attempting, <0 = failed
        public static int RelayStatus() =>
            s_utils == IntPtr.Zero ? 0 : SteamAPI_ISteamNetworkingUtils_GetRelayNetworkStatus(s_utils, IntPtr.Zero);

        public static void Send(byte[] pkt)
        {
            LastSendResult = SteamAPI_ISteamNetworkingMessages_SendMessageToUser(
                s_msgs, s_peerIdentity, pkt, (uint)pkt.Length, SendUnreliableNoNagle | SendAutoRestart, s_channel);
        }

        // Events (enemy deaths...) must arrive: Steam retransmits and keeps them in order.
        public static void SendReliable(byte[] pkt)
        {
            LastSendResult = SteamAPI_ISteamNetworkingMessages_SendMessageToUser(
                s_msgs, s_peerIdentity, pkt, (uint)pkt.Length, SendFlagReliable | SendAutoRestart, s_channel);
        }

        // Non-blocking: drains whatever arrived since the last call.
        public static void Poll(Action<byte[], ulong> onPacket)
        {
            int n = SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel(s_msgs, s_channel, s_inbox, s_inbox.Length);
            for (int i = 0; i < n; i++)
            {
                var m = s_inbox[i];
                // SteamNetworkingMessage_t: void* m_pData @0, int m_cbSize @8, identity @16
                var data = Marshal.ReadIntPtr(m, 0);
                var size = Marshal.ReadInt32(m, 8);
                var from = SteamAPI_SteamNetworkingIdentity_GetSteamID64(m + 16);
                var buf = new byte[Math.Max(0, size)];
                if (size > 0) Marshal.Copy(data, buf, 0, size);
                SteamAPI_SteamNetworkingMessage_t_Release(m);
                onPacket(buf, from);
            }
        }

        public static void Shutdown()
        {
            if (s_peerIdentity != IntPtr.Zero) { Marshal.FreeHGlobal(s_peerIdentity); s_peerIdentity = IntPtr.Zero; }
        }
    }

    struct Sample
    {
        public uint Seq;
        public double T;
        public float Px, Py, Pz, Qx, Qy, Qz, Qw;
        public uint Bank, Id;
        public float Frame;
        public float LookYaw, LookPitch;   // camera relative to body, radians
    }

    const string Version = "0.23";
    const int PacketSize = 64;
    static readonly byte[] Magic = { (byte)'R', (byte)'7', (byte)'C', (byte)'2' };
    const int KeepSamples = 32;

    static string s_dataDir;
    static Config s_cfg;
    static UdpClient s_sock;
    static IPEndPoint s_peer;
    static Thread s_recvThread, s_ioThread;
    static volatile bool s_running;

    static readonly object s_lock = new object();
    static readonly LinkedList<Sample> s_received = new LinkedList<Sample>();
    static bool s_inDirty;
    static long s_sent, s_recv, s_bad;
    static string s_lastFrom = "-";
    static uint s_lastSentSeq;

    [PluginEntryPoint]
    public static void Main()
    {
        try
        {
            var exe = Process.GetCurrentProcess().MainModule.FileName;
            s_dataDir = Path.Combine(Path.GetDirectoryName(exe), "reframework", "data");
            Directory.CreateDirectory(s_dataDir);
            s_cfg = LoadConfig();
            s_running = true;

            // Steam starts in every mode so the in-game Connect panel can show our own
            // SteamID and switch to a friend live, even from bot mode.
            try { Steam.Init(s_cfg.steamChannel); s_steamReady = true; }
            catch (Exception e) { API.LogWarning("[CoopNet] Steam unavailable: " + e.Message); }
            if (s_steamReady) BackupSaves("launch");   // a fresh copy every time the mod starts
            if (s_steamReady) Steam.SetPresence("coop_re7", Version);   // friends' Connect lists show us

            if (IsSteam)
            {
                if (!s_steamReady) throw new InvalidOperationException("steam mode but Steam is unavailable");
                var want = (s_cfg.peerSteamId ?? "").Trim();
                s_peerSteam = want == "self" ? Steam.SelfId          // loopback experiment
                    : ulong.TryParse(want, NumberStyles.None, Inv, out var id) ? id : 0;  // 0: just show our own id
                Steam.SetPeer(s_peerSteam);
                if (s_peerSteam != Steam.SelfId) Steam.SetPresence("coop_re7_to", s_peerSteam == 0 ? "" : s_peerSteam.ToString(Inv));
                API.LogInfo($"[CoopNet] steam self={Steam.SelfId} ({Steam.SelfName}) peer={s_peerSteam}");
            }
            else if (s_cfg.mode == "bot")
            {
                API.LogInfo("[CoopNet] bot mode: fake peer around the local player");
            }
            else
            {
                var bind = new IPEndPoint(IPAddress.Parse(s_cfg.bindHost), s_cfg.localPort);
                s_sock = new UdpClient(bind);
                s_peer = s_cfg.mode == "echo"
                    ? new IPEndPoint(IPAddress.Loopback, s_cfg.localPort)
                    : new IPEndPoint(Dns.GetHostAddresses(s_cfg.peerHost)[0], s_cfg.peerPort);
                s_recvThread = new Thread(RecvLoop) { IsBackground = true, Name = "CoopNet.Recv" };
                s_recvThread.Start();
            }

            s_ioThread = new Thread(IoLoop) { IsBackground = true, Name = "CoopNet.IO" };
            s_ioThread.Start();
            API.LogInfo($"[CoopNet] started mode={s_cfg.mode} peer={PeerText} sendHz={s_cfg.sendHz}");
            WriteStatus("started");
        }
        catch (Exception e)
        {
            API.LogError("[CoopNet] start failed: " + e);
            WriteStatusSafe("start failed: " + e.Message);
        }
    }

    [PluginExitPoint]
    public static void OnUnload()
    {
        s_running = false;
        try { s_sock?.Close(); } catch { }
        s_recvThread?.Join(1000);
        s_ioThread?.Join(1000);
        if (s_steamReady) { Steam.SetPresence("coop_re7", ""); Steam.SetPresence("coop_re7_to", ""); }
        if (IsSteam) Steam.Shutdown();
        API.LogInfo("[CoopNet] stopped");
    }

    static ulong s_peerSteam;
    static bool s_steamReady;
    static string s_lastCommand = "-";

    // In-game Connect panel: Lua writes one line to coopnet_command.txt
    // ("steam <SteamID64>" or "bot"); applied here live and saved to the config.
    static void PollCommand()
    {
        var path = Path.Combine(s_dataDir, "coopnet_command.txt");
        if (!File.Exists(path)) return;
        string cmd;
        try { cmd = File.ReadAllText(path).Trim(); File.Delete(path); }
        catch (IOException) { return; }
        var parts = cmd.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 2 && parts[0] == "steam" && s_steamReady &&
            ulong.TryParse(parts[1], NumberStyles.None, Inv, out var id) && id > 76561197960265728UL)
        {
            s_cfg.mode = "steam";
            s_cfg.peerSteamId = parts[1];
            s_peerSteam = id;
            Steam.SetPeer(id);
            Steam.SetPresence("coop_re7_to", parts[1]);   // shows as an invite on the friend's side
            s_lastCommand = "connected to " + parts[1];
        }
        else if (parts.Length == 1 && parts[0] == "bot")
        {
            s_cfg.mode = "bot";
            s_cfg.botChapter = -1;   // a fresh bot stands in our chapter (it was saved with the config)
            if (s_steamReady) Steam.SetPresence("coop_re7_to", "");
            s_lastCommand = "bot test";
        }
        else if (parts.Length >= 2 && parts[0] == "botevent")
        {
            Bot.QueueEvent(s_cfg, cmd.Substring("botevent ".Length));   // the bot "does" something
            s_lastCommand = "bot event: " + cmd.Substring("botevent ".Length);
            WriteStatus("running");
            return;
        }
        else if (parts.Length == 2 && parts[0] == "botmode" && (parts[1] == "follow" || parts[1] == "circle" || parts[1] == "stay"))
        {
            s_cfg.botMode = parts[1];
            Bot.Recenter();   // circle mode starts around where we are now
            s_lastCommand = "bot mode: " + parts[1];
            SaveConfig();
            WriteStatus("running");
            return;
        }
        else if (parts.Length == 1 && parts[0] == "botrecenter")
        {
            Bot.Recenter();   // centre on the next position we send
            s_lastCommand = "bot re-centred";
            WriteStatus("running");
            return;
        }
        else if (parts.Length == 2 && parts[0] == "botchapter" && int.TryParse(parts[1], NumberStyles.AllowLeadingSign, Inv, out var ch))
        {
            s_cfg.botChapter = ch;   // test "Join my friend": the bot claims another chapter
            s_lastCommand = "bot chapter " + ch;
            WriteStatus("running");
            return;   // not saved: the next launch starts with the bot beside us again
        }
        else if (parts.Length == 1 && parts[0] == "report")
        {
            s_lastCommand = MakeReport();
            WriteStatus("running");
            return;
        }
        else if (parts.Length == 2 && parts[0] == "backup")
        {
            BackupSaves(parts[1]);
            s_lastCommand = "save backup (" + parts[1] + ")";
            WriteStatus("running");
            return;   // nothing else changes
        }
        else
        {
            s_lastCommand = "rejected: " + cmd;
            WriteStatus("running");
            return;
        }
        lock (s_lock) { s_received.Clear(); s_inDirty = true; }   // drop the old peer's samples
        SaveConfig();
        API.LogInfo("[CoopNet] command: " + s_lastCommand);
        WriteStatus("running");
    }

    // Events --------------------------------------------------------------------------
    // Things that happen once (an enemy died) go reliably, as "R7E1" + UTF-8 text.
    // Lua -> coopnet_ev_out.txt: "<id>	<text>" lines with ever-growing ids; we send each
    // new id once. Received events -> coopnet_ev_in.txt: "<n>	<text>" (last 50), and
    // Lua handles each n once.
    static readonly byte[] EventMagic = { (byte)'R', (byte)'7', (byte)'E', (byte)'1' };
    static readonly List<(long n, string text)> s_evIn = new List<(long, string)>();
    static long s_evInCount, s_evOutLast = -1, s_evSent, s_evRecv;
    static bool s_evInDirty;

    static byte[] EncodeEvent(string text)
    {
        var body = Encoding.UTF8.GetBytes(text);
        var pkt = new byte[4 + body.Length];
        Buffer.BlockCopy(EventMagic, 0, pkt, 0, 4);
        Buffer.BlockCopy(body, 0, pkt, 4, body.Length);
        return pkt;
    }

    static bool IsEvent(byte[] d) =>
        d.Length >= 4 && d[0] == EventMagic[0] && d[1] == EventMagic[1] && d[2] == EventMagic[2] && d[3] == EventMagic[3];

    static void OnEvent(string text)
    {
        lock (s_lock)
        {
            s_evIn.Add((++s_evInCount, text.Replace('\n', ' ').Replace('\r', ' ')));
            while (s_evIn.Count > 50) s_evIn.RemoveAt(0);
            s_evInDirty = true;
            s_evRecv++;
        }
    }

    static void PumpEventsOut(string path)
    {
        string[] lines;
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs);
            lines = sr.ReadToEnd().Split('\n');
        }
        catch (FileNotFoundException) { if (s_evOutLast < 0) s_evOutLast = 0; return; }   // nothing sent yet
        catch (IOException) { return; }
        catch (UnauthorizedAccessException) { return; }
        // First look after a (re)start: what's already in the file was sent before.
        bool first = s_evOutLast < 0;
        foreach (var line in lines)
        {
            var tab = line.IndexOf('\t');
            if (tab <= 0 || !long.TryParse(line.AsSpan(0, tab), NumberStyles.None, Inv, out var id)) continue;
            if (first) { s_evOutLast = Math.Max(s_evOutLast, id); continue; }
            if (id <= s_evOutLast) continue;
            s_evOutLast = id;
            var text = line.Substring(tab + 1).TrimEnd('\r');
            var pkt = EncodeEvent(text);
            if (IsSteam) { if (s_peerSteam != 0) { Steam.SendReliable(pkt); s_evSent++; } }
            else if (s_sock != null) { s_sock.Send(pkt, pkt.Length, s_peer); s_evSent++; }
            // The bot copies our moves, so it also holds what we hold.
            else if (s_cfg.mode == "bot" && (text.StartsWith("weapon ") || text.StartsWith("bank ") || text.StartsWith("grip ")
                || text.StartsWith("talk ") || text.StartsWith("catchup ") || text.StartsWith("hp ")))
                Bot.QueueEvent(s_cfg, text);
        }
        if (s_evOutLast < 0) s_evOutLast = 0;
    }

    static void WriteEventsInIfDirty(string path)
    {
        string text;
        lock (s_lock)
        {
            if (!s_evInDirty) return;
            s_evInDirty = false;
            var sb = new StringBuilder();
            foreach (var (n, t) in s_evIn) sb.Append(n.ToString(Inv)).Append('\t').Append(t).Append('\n');
            text = sb.ToString();
        }
        File.WriteAllText(path + ".tmp", text);
        File.Move(path + ".tmp", path, true);
    }

    // Enemy snapshots ------------------------------------------------------------------
    // The game that controls the enemies writes coopnet_es_out.txt (first line "seq <n>",
    // then one line per awake enemy) about 10 times a second. Each new seq goes out
    // unreliably as "R7S1" + UTF-8 text: only the newest matters, like player movement.
    // A received snapshot replaces coopnet_es_in.txt.
    static readonly byte[] SnapMagic = { (byte)'R', (byte)'7', (byte)'S', (byte)'1' };
    static string s_snapOutSeq = "";
    static string s_snapIn;
    static long s_snapSent, s_snapRecv;

    static bool IsSnap(byte[] d) =>
        d.Length >= 4 && d[0] == SnapMagic[0] && d[1] == SnapMagic[1] && d[2] == SnapMagic[2] && d[3] == SnapMagic[3];

    static void PumpSnapshotOut(string path)
    {
        string text;
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs);
            text = sr.ReadToEnd();
        }
        catch (IOException) { return; }
        catch (UnauthorizedAccessException) { return; }
        var nl = text.IndexOf('\n');
        if (nl <= 0 || !text.StartsWith("seq ")) return;
        var seq = text.Substring(0, nl);
        if (seq == s_snapOutSeq) return;
        s_snapOutSeq = seq;
        var body = Encoding.UTF8.GetBytes(text);
        if (body.Length > 1100) return;   // stay in one unfragmented message
        var pkt = new byte[4 + body.Length];
        Buffer.BlockCopy(SnapMagic, 0, pkt, 0, 4);
        Buffer.BlockCopy(body, 0, pkt, 4, body.Length);
        if (IsSteam) { if (s_peerSteam != 0) { Steam.Send(pkt); s_snapSent++; } }
        else if (s_sock != null) { s_sock.Send(pkt, pkt.Length, s_peer); s_snapSent++; }
    }

    static void WriteSnapshotInIfNew(string path)
    {
        string text;
        lock (s_lock) { text = s_snapIn; s_snapIn = null; }
        if (text == null) return;
        File.WriteAllText(path + ".tmp", text);
        File.Move(path + ".tmp", path, true);
    }

    // Save backups ------------------------------------------------------------------
    // Copies the game's Steam save folder (userdata\<id>\418370\remote) into
    // reframework/data/save_backups/<stamp>_<reason>/, keeping the newest N. Runs at
    // every plugin start and on the "backup" command (sent when saving is allowed).
    static string s_lastBackup = "-";
    static int s_backupCount;

    static void BackupSaves(string reason)
    {
        try
        {
            var local = Steam.UserDataFolder();
            if (string.IsNullOrEmpty(local)) { s_lastBackup = "no Steam user folder"; return; }
            var remote = Path.Combine(Path.GetDirectoryName(local.TrimEnd('\\', '/')), "remote");
            if (!Directory.Exists(remote)) { s_lastBackup = "no save folder yet"; return; }
            var root = Path.Combine(s_dataDir, "save_backups");
            var dest = Path.Combine(root, $"{DateTime.Now:yyyyMMdd_HHmmss}_{reason}");
            int files = 0;
            foreach (var src in Directory.GetFiles(remote, "*", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(remote, src);
                var to = Path.Combine(dest, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(to));
                File.Copy(src, to, true);
                files++;
            }
            var all = Directory.GetDirectories(root);
            Array.Sort(all, StringComparer.Ordinal);
            for (int i = 0; i < all.Length - Math.Max(1, s_cfg.saveBackupsKeep); i++) Directory.Delete(all[i], true);
            s_backupCount = Math.Min(all.Length, Math.Max(1, s_cfg.saveBackupsKeep));
            s_lastBackup = $"{DateTime.Now:HH:mm:ss} {reason} ({files} files)";
            API.LogInfo("[CoopNet] save backup: " + dest + " (" + files + " files)");
        }
        catch (Exception e) { s_lastBackup = "FAILED: " + e.Message; API.LogWarning("[CoopNet] save backup failed: " + e); }
    }

    // Bug report: the co-op logs and settings plus REFramework's log, copied to a folder on
    // the desktop and zipped there. SteamIDs, Steam names (ours and the friend list's) and
    // the Windows user name are blanked out, so the zip can be posted as it is.
    static string MakeReport()
    {
        try
        {
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", Inv);
            var desk = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
            var dir = Path.Combine(desk, "coop-re7-report-" + stamp);
            Directory.CreateDirectory(dir);
            var names = new List<string>();
            var status = Path.Combine(s_dataDir, "coopnet_status.txt");
            foreach (var line in ReadShared(status).Split('\n'))
                if (line.StartsWith("steamName=")) names.Add(line.Substring(10).Trim());
            foreach (var line in ReadShared(Path.Combine(s_dataDir, "coopnet_friends.txt")).Split('\n'))
            {
                var cols = line.Split('\t');
                if (cols.Length >= 4 && cols[3].Trim().Length > 0) names.Add(cols[3].Trim());
            }
            var user = Environment.UserName;
            int n = 0;
            var files = new List<string>();
            foreach (var pat in new[] { "coop_*_log.txt", "coop_dummy_log_prev.txt", "coop_settings.json",
                         "coop_story_played.json", "coopnet_status.txt", "coopnet_config.json" })
                files.AddRange(Directory.GetFiles(s_dataDir, pat));
            var fwLog = Path.GetFullPath(Path.Combine(s_dataDir, "..", "..", "re2_framework_log.txt"));
            if (File.Exists(fwLog)) files.Add(fwLog);
            foreach (var f in files)
            {
                var text = Scrub(ReadShared(f), names, user);
                File.WriteAllText(Path.Combine(dir, Path.GetFileName(f)), text);
                n++;
            }
            string q(string x) => x.Replace("'", "''");
            var psi = new ProcessStartInfo("powershell",
                $"-NoProfile -WindowStyle Hidden -Command \"Compress-Archive -Path '{q(dir)}\\*' -DestinationPath '{q(dir)}.zip' -Force; if ($?) {{ Remove-Item -Recurse -Force '{q(dir)}' }}\"")
                { CreateNoWindow = true, UseShellExecute = false };
            Process.Start(psi);
            API.LogInfo("[CoopNet] bug report: " + dir + ".zip (" + n + " files)");
            return "bug report on your desktop: coop-re7-report-" + stamp + ".zip (" + n + " files)";
        }
        catch (Exception e) { API.LogWarning("[CoopNet] bug report failed: " + e); return "bug report FAILED: " + e.Message; }
    }

    static string ReadShared(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs);
            return sr.ReadToEnd();
        }
        catch (Exception) { return ""; }
    }

    static string Scrub(string text, List<string> names, string user)
    {
        var sb = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++)
        {
            // SteamID64s: 7656119 followed by 10 more digits.
            if (i + 17 <= text.Length && string.CompareOrdinal(text, i, "7656119", 0, 7) == 0)
            {
                int j = i + 7;
                while (j < i + 17 && char.IsDigit(text[j])) j++;
                if (j == i + 17 && (j == text.Length || !char.IsDigit(text[j]))) { sb.Append("<steamid>"); i = j - 1; continue; }
            }
            sb.Append(text[i]);
        }
        var outText = sb.ToString();
        foreach (var nm in names) if (nm.Length >= 2) outText = outText.Replace(nm, "<name>");
        if (!string.IsNullOrEmpty(user) && user.Length >= 2) outText = outText.Replace(user, "<user>");
        return outText;
    }

    static void SaveConfig()
    {
        var path = Path.Combine(s_dataDir, "coopnet_config.json");
        File.WriteAllText(path, JsonSerializer.Serialize(s_cfg, new JsonSerializerOptions { WriteIndented = true }));
    }
    static bool IsSteam => s_cfg != null && s_cfg.mode == "steam";
    static string PeerText => IsSteam ? $"steam:{s_peerSteam}" : s_peer?.ToString() ?? "-";

    static void OnPacket(byte[] data, string from)
    {
        if (IsEvent(data)) { OnEvent(Encoding.UTF8.GetString(data, 4, data.Length - 4)); return; }
        if (IsSnap(data))
        {
            lock (s_lock) { s_snapIn = Encoding.UTF8.GetString(data, 4, data.Length - 4); s_snapRecv++; }
            return;
        }
        if (!TryDecode(data, out var s)) { Interlocked.Increment(ref s_bad); return; }
        lock (s_lock)
        {
            s_received.AddLast(s);
            while (s_received.Count > KeepSamples) s_received.RemoveFirst();
            s_inDirty = true;
            s_recv++;
            s_lastFrom = from;
        }
    }

    static Config LoadConfig()
    {
        var path = Path.Combine(s_dataDir, "coopnet_config.json");
        if (!File.Exists(path))
        {
            var def = new Config();
            File.WriteAllText(path, JsonSerializer.Serialize(def, new JsonSerializerOptions { WriteIndented = true }));
            return def;
        }
        return JsonSerializer.Deserialize<Config>(File.ReadAllText(path)) ?? new Config();
    }

    // Receive thread ----------------------------------------------------------

    static void RecvLoop()
    {
        var from = new IPEndPoint(IPAddress.Any, 0);
        while (s_running)
        {
            byte[] data;
            try { data = s_sock.Receive(ref from); }
            catch (SocketException) { if (!s_running) return; continue; }
            catch (ObjectDisposedException) { return; }

            OnPacket(data, from.ToString());
        }
    }

    // IO thread: Lua out-file -> socket, received samples -> Lua in-file ---------

    static void IoLoop()
    {
        var outPath = Path.Combine(s_dataDir, "coopnet_out.txt");
        var inPath = Path.Combine(s_dataDir, "coopnet_in.txt");
        var evOutPath = Path.Combine(s_dataDir, "coopnet_ev_out.txt");
        var esOutPath = Path.Combine(s_dataDir, "coopnet_es_out.txt");
        var esInPath = Path.Combine(s_dataDir, "coopnet_es_in.txt");
        try { File.Delete(esInPath); } catch (IOException) { }   // no stale enemy positions from a past session
        var evInPath = Path.Combine(s_dataDir, "coopnet_ev_in.txt");
        try { File.Delete(evInPath); } catch (IOException) { }   // a new count starts at 1; Lua notices the reset
        var period = TimeSpan.FromMilliseconds(1000.0 / Math.Max(1, s_cfg.sendHz));
        var lastStatus = Stopwatch.StartNew();
        var lastFriends = Stopwatch.StartNew();

        while (s_running)
        {
            var started = Stopwatch.StartNew();
            try
            {
                if (TryReadOut(outPath, out var s) && s.Seq != s_lastSentSeq)
                {
                    s_lastSentSeq = s.Seq;
                    var pkt = Encode(s);
                    if (IsSteam)
                    {
                        if (s_peerSteam != 0) { Steam.Send(pkt); s_sent++; }
                    }
                    else if (s_cfg.mode == "bot")
                    {
                        Bot.SetCenter(s);   // circle mode: the bot circles where we first stood
                        Bot.Record(s);      // follow mode: our path is the bot's trail
                        Bot.LastLocal = s;
                    }
                    else
                    {
                        s_sock.Send(pkt, pkt.Length, s_peer);
                        s_sent++;
                    }
                }
                PollCommand();
                if (IsSteam) Steam.Poll((data, from) => OnPacket(data, "steam:" + from));
                if (s_cfg.mode == "bot") { Bot.Tick(s_cfg, pkt => OnPacket(pkt, "bot")); s_sent++; }
                PumpEventsOut(evOutPath);
                PumpSnapshotOut(esOutPath);
                WriteSnapshotInIfNew(esInPath);
                WriteInFileIfDirty(inPath);
                WriteEventsInIfDirty(evInPath);
                if (lastStatus.ElapsedMilliseconds > 1000)
                {
                    lastStatus.Restart();
                    WriteStatus("running");
                }
                if (s_steamReady && lastFriends.ElapsedMilliseconds > 2000)
                {
                    lastFriends.Restart();
                    WriteFriends();
                }
            }
            catch (ObjectDisposedException) { return; }
            catch (Exception e) { WriteStatusSafe("io error: " + e.Message); }

            var left = period - started.Elapsed;
            if (left > TimeSpan.Zero) Thread.Sleep(left);
        }
    }

    static bool TryReadOut(string path, out Sample s)
    {
        s = default;
        string line;
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs);
            line = sr.ReadLine();
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        return line != null && TryParseLine(line, out s);
    }

    static void WriteInFileIfDirty(string path)
    {
        string text;
        lock (s_lock)
        {
            if (!s_inDirty) return;
            s_inDirty = false;
            var sb = new StringBuilder();
            foreach (var s in s_received) sb.AppendLine(FormatLine(s));
            text = sb.ToString();
        }
        // Replace atomically so Lua never reads a half-written file.
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, text);
        File.Move(tmp, path, true);
    }

    static void WriteStatus(string state)
    {
        string text;
        lock (s_lock)
        {
            text = $"state={state}\nmode={s_cfg.mode}\npeer={PeerText}\nsent={s_sent}\nrecv={s_recv}\nbad={s_bad}\nlastFrom={s_lastFrom}\n" +
                   $"time={DateTime.Now:HH:mm:ss}\n";
            if (s_cfg.mode == "bot") text += $"botExpect={Bot.Expect}\n";
            if (s_steamReady)
                text += $"steamSelf={Steam.SelfId}\nsteamName={Steam.SelfName}\nrelayStatus={Steam.RelayStatus()}\n";
            if (IsSteam) text += $"lastSendResult={Steam.LastSendResult}\npeerName={Steam.PeerName()}\n";
            text += $"lastCommand={s_lastCommand}\nlastBackup={s_lastBackup}\nbackups={s_backupCount}\nversion={Version}\nevSent={s_evSent}\nevRecv={s_evRecv}\nsnapSent={s_snapSent}\nsnapRecv={s_snapRecv}\n";
            text += $"fullModels={FullModels()}\n";
        }
        WriteStatusSafe(text);
    }

    // "Third Person Full Model Placeholders" (Nexus RE7 mod 86, installed as loose files)
    // replaces the players' incomplete shadow models with complete ones under the same
    // paths. REFramework only reads loose files with its Loose File Loader on, so:
    // "1" = files present and loader on, "off" = files present but loader off, "0" = none.
    // Re-checked every 10 s (players copy the files in while the game runs).
    static string s_fullModels = "0";
    static DateTime s_fullModelsAt = DateTime.MinValue;
    static string FullModels()
    {
        if ((DateTime.Now - s_fullModelsAt).TotalSeconds < 10) return s_fullModels;
        s_fullModelsAt = DateTime.Now;
        try
        {
            var game = Path.GetFullPath(Path.Combine(s_dataDir, "..", ".."));
            // "Use full models.cmd" moves the mod's models under natives\stm\coop (left in
            // place they also replace the player's own first-person body).
            var f = Path.Combine(game, "natives", "stm", "coop", "character", "player", "pl2000", "pl2001", "pl2001.mesh.220128762");
            var unmoved = Path.Combine(game, "natives", "stm", "character", "player", "pl2000", "pl2001", "pl2001.mesh.220128762");
            if (!File.Exists(f)) { s_fullModels = File.Exists(unmoved) ? "move" : "0"; return s_fullModels; }
            var cfg = ReadShared(Path.Combine(game, "re2_fw_config.txt"));
            s_fullModels = cfg.Contains("LooseFileLoader_Enabled=true") ? "1" : "off";
        }
        catch (Exception) { s_fullModels = "0"; }
        return s_fullModels;
    }

    // coopnet_friends.txt for the Connect list: id<TAB>flags<TAB>coop version<TAB>name,
    // flags R = in RE7, C = co-op running, I = inviting us. Online friends only.
    static void WriteFriends()
    {
        var sb = new StringBuilder();
        foreach (var f in Steam.Friends())
        {
            var flags = (f.InRe7 ? "R" : "") + (f.CoopVersion != "" ? "C" : "") + (f.InvitesMe ? "I" : "");
            var name = f.Name.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
            sb.Append(f.Id.ToString(Inv)).Append('\t').Append(flags == "" ? "-" : flags).Append('\t')
              .Append(f.CoopVersion == "" ? "-" : f.CoopVersion).Append('\t').Append(name).Append('\n');
        }
        var path = Path.Combine(s_dataDir, "coopnet_friends.txt");
        File.WriteAllText(path + ".tmp", sb.ToString());
        File.Move(path + ".tmp", path, true);
    }

    static void WriteStatusSafe(string text)
    {
        try { if (s_dataDir != null) File.WriteAllText(Path.Combine(s_dataDir, "coopnet_status.txt"), text); } catch { }
    }

    // Text line <-> sample: "seq t px py pz qx qy qz qw bank id frame" ----------

    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    static bool TryParseLine(string line, out Sample s)
    {
        s = default;
        var p = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (p.Length < 14) return false;
        try
        {
            s.Seq = uint.Parse(p[0], Inv);
            s.T = double.Parse(p[1], Inv);
            s.Px = float.Parse(p[2], Inv); s.Py = float.Parse(p[3], Inv); s.Pz = float.Parse(p[4], Inv);
            s.Qx = float.Parse(p[5], Inv); s.Qy = float.Parse(p[6], Inv); s.Qz = float.Parse(p[7], Inv); s.Qw = float.Parse(p[8], Inv);
            s.Bank = uint.Parse(p[9], Inv); s.Id = uint.Parse(p[10], Inv);
            s.Frame = float.Parse(p[11], Inv);
            s.LookYaw = float.Parse(p[12], Inv); s.LookPitch = float.Parse(p[13], Inv);
            return true;
        }
        catch (FormatException) { return false; }
        catch (OverflowException) { return false; }
    }

    static string FormatLine(Sample s) => string.Format(Inv,
        "{0} {1:R} {2:R} {3:R} {4:R} {5:R} {6:R} {7:R} {8:R} {9} {10} {11:R} {12:R} {13:R}",
        s.Seq, s.T, s.Px, s.Py, s.Pz, s.Qx, s.Qy, s.Qz, s.Qw, s.Bank, s.Id, s.Frame, s.LookYaw, s.LookPitch);

    // Binary packet <-> sample ----------------------------------------------------

    static byte[] Encode(Sample s)
    {
        var b = new byte[PacketSize];
        var w = new BinaryWriter(new MemoryStream(b));
        w.Write(Magic);
        w.Write(s.Seq); w.Write(s.T);
        w.Write(s.Px); w.Write(s.Py); w.Write(s.Pz);
        w.Write(s.Qx); w.Write(s.Qy); w.Write(s.Qz); w.Write(s.Qw);
        w.Write(s.Bank); w.Write(s.Id); w.Write(s.Frame);
        w.Write(s.LookYaw); w.Write(s.LookPitch);
        return b;
    }

    static bool TryDecode(byte[] b, out Sample s)
    {
        s = default;
        if (b.Length != PacketSize || b[0] != Magic[0] || b[1] != Magic[1] || b[2] != Magic[2] || b[3] != Magic[3])
            return false;
        var r = new BinaryReader(new MemoryStream(b, 4, PacketSize - 4));
        s.Seq = r.ReadUInt32(); s.T = r.ReadDouble();
        s.Px = r.ReadSingle(); s.Py = r.ReadSingle(); s.Pz = r.ReadSingle();
        s.Qx = r.ReadSingle(); s.Qy = r.ReadSingle(); s.Qz = r.ReadSingle(); s.Qw = r.ReadSingle();
        s.Bank = r.ReadUInt32(); s.Id = r.ReadUInt32(); s.Frame = r.ReadSingle();
        s.LookYaw = r.ReadSingle(); s.LookPitch = r.ReadSingle();
        return true;
    }
}
