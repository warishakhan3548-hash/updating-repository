using System;

namespace Aaris.World
{
    public sealed class InputPulse
    {
        private bool pending;
        private double timestamp;
        public void Request(double now)
        { if (!WorldValidator.Finite(now)) throw new ArgumentException("Finite input timestamp required."); timestamp = now; pending = true; }
        public bool Consume(double now, double lifetime)
        {
            bool available = pending; pending = false;
            return available && WorldValidator.Finite(now) && now >= timestamp && now - timestamp <= lifetime;
        }
        public void Clear() { pending = false; }
    }
    // Shared timing/state policies; these do not replace the native physics solver.
    public sealed class JumpGate
    {
        private readonly double coyote, buffer;
        private double lastGround = double.NegativeInfinity, requested = double.NegativeInfinity;
        private bool consumed, sawAir;
        public JumpGate(double coyote, double buffer) { this.coyote = coyote; this.buffer = buffer; }
        public void Request(double now) { requested = now; }
        public bool Tick(double now, bool grounded)
        {
            if (!grounded) sawAir = true;
            if (grounded) { lastGround = now; if (sawAir) { consumed = false; sawAir = false; } }
            if (consumed || now - requested > buffer + 1e-9 || now - lastGround > coyote + 1e-9) return false;
            consumed = true; requested = double.NegativeInfinity; return true;
        }
        public void Reset() { lastGround = requested = double.NegativeInfinity; consumed = sawAir = false; }
    }

    public sealed class WeaponState
    {
        private readonly WeaponSpec spec;
        private double nextShot, reloadEnd = double.PositiveInfinity, lastTime = double.NegativeInfinity;
        public int Ammo { get; private set; }
        public int Reserve { get; private set; }
        public bool Reloading { get; private set; }
        public WeaponState(WeaponSpec spec) { this.spec = spec; Reset(); }
        public void Reset() { Ammo = spec.magazine; Reserve = spec.reserve; nextShot = 0; Reloading = false; reloadEnd = double.PositiveInfinity; lastTime = double.NegativeInfinity; }
        public bool Tick(double now, bool fire, bool reload)
        {
            if (!WorldValidator.Finite(now) || now < lastTime) throw new ArgumentException("Weapon clock must be finite and monotonic.");
            lastTime = now;
            if (Reloading && now + 1e-9 >= reloadEnd)
            { int transfer = Math.Min(spec.magazine - Ammo, Reserve); Ammo += transfer; Reserve -= transfer; Reloading = false; }
            if ((reload || (fire && Ammo == 0)) && !Reloading && Ammo < spec.magazine && Reserve > 0)
            { Reloading = true; reloadEnd = now + spec.reloadSeconds; }
            if (!fire || Reloading || Ammo == 0 || now + 1e-9 < nextShot) return false;
            Ammo--;
            double scheduled = nextShot + 1 / spec.roundsPerSecond;
            // Keep the phase across fixed-step rounding, but skip missed slots after a hitch.
            nextShot = scheduled > now ? scheduled : now + 1 / spec.roundsPerSecond;
            return true;
        }
    }

    public enum TouchRole { Move, Look, Fire, Jump, Reload, Sprint, Aim }
    public struct ControlRect
    {
        public double x, y, width, height;
        public ControlRect(double x, double y, double width, double height) { this.x = x; this.y = y; this.width = width; this.height = height; }
        public bool Contains(double px, double py) => px >= x && px <= x + width && py >= y && py <= y + height;
    }
    public static class ControlLayout
    {
        // Coordinates are safe-area normalized, bottom-left origin. Render and input share these rectangles.
        public static ControlRect Rect(TouchRole role)
        {
            switch (role)
            {
                case TouchRole.Move: return new ControlRect(0.02, 0.02, 0.36, 0.43);
                case TouchRole.Fire: return new ControlRect(0.84, 0.29, 0.14, 0.21);
                case TouchRole.Jump: return new ControlRect(0.84, 0.04, 0.14, 0.19);
                case TouchRole.Reload: return new ControlRect(0.68, 0.04, 0.13, 0.15);
                case TouchRole.Aim: return new ControlRect(0.68, 0.23, 0.13, 0.15);
                case TouchRole.Sprint: return new ControlRect(0.02, 0.50, 0.13, 0.15);
                default: return new ControlRect(0.39, 0.02, 0.59, 0.94);
            }
        }
    }

    public sealed class TouchOwnership
    {
        private struct Finger { public int id; public TouchRole role; public double startX, startY; }
        private readonly Finger[] fingers = new Finger[10];
        private static readonly TouchRole[] Priority = { TouchRole.Fire, TouchRole.Jump, TouchRole.Reload, TouchRole.Aim, TouchRole.Sprint, TouchRole.Move };
        private int count;
        public int Count => count;
        public bool Begin(int id, double x, double y)
        {
            if (!WorldValidator.Finite(x, y) || x < 0 || x > 1 || y < 0 || y > 1 || count == fingers.Length || Find(id) >= 0) return false;
            var role = TouchRole.Look;
            foreach (var candidate in Priority)
                if (ControlLayout.Rect(candidate).Contains(x, y)) { role = candidate; break; }
            // One owner per control prevents one lifted finger from clearing another's input.
            for (int i = 0; i < count; i++) if (fingers[i].role == role) return false;
            fingers[count++] = new Finger { id = id, role = role, startX = x, startY = y }; return true;
        }
        public bool Get(int id, out TouchRole role, out Point2 origin)
        {
            int i = Find(id); role = i >= 0 ? fingers[i].role : TouchRole.Look;
            origin = i >= 0 ? new Point2(fingers[i].startX, fingers[i].startY) : new Point2(); return i >= 0;
        }
        public bool Held(TouchRole role) { for (int i = 0; i < count; i++) if (fingers[i].role == role) return true; return false; }
        public void End(int id) { int i = Find(id); if (i >= 0) fingers[i] = fingers[--count]; }
        public void Prune(ReadOnlySpan<int> active)
        {
            for (int i = 0; i < count;)
            {
                bool present = false; for (int j = 0; j < active.Length; j++) present |= active[j] == fingers[i].id;
                if (present) i++; else fingers[i] = fingers[--count];
            }
        }
        public void Clear() { count = 0; }
        private int Find(int id) { for (int i = 0; i < count; i++) if (fingers[i].id == id) return i; return -1; }
    }
}
