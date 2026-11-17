// Clip specifications for the synthetic test bed. Each clip is 30 fps, 720x1280 portrait, phone lens 72.5 deg
// (vertical), unless it says otherwise. Distances in feet, slab sizes in inches, angles in degrees.
// Camera: D = line-of-sight distance to the slab's top centre, el = elevation above horizontal, az = compass
// position around the slab; yaw/pitch/roll aim the phone off the slab. Shake 1 = normal hand-held.
"use strict";

const base = () => ({
  fps: 30, frames: 120,
  slab: { size: 7, aspect: 1, thick: 0.9, sag: 0.1, bevel: 0.05, tilt: 10, heading: 0, yaw: 20 },
  base: { sx: 1.12, sz: 1.06, yawOff: 12, chamfer: 1.0, minH: 1.3, rough: 0.45 },
  floor: "mat",
  light: { type: "indoor", level: 1, amb: 0.8, sun: 2.2, el: 50, az: 30 },
  cam: { fov: 72.5, keys: [{ t: 0, D: 4, el: 50, az: 0, yaw: 0, pitch: 0, roll: 0 }], shake: 1, k1: 0 },
  expo: { target: 0.42 }, noise: 1, sensor: { bias: 0.3, noise: 1 },
});
function merge(a, b) { for (const k in b) { if (b[k] && typeof b[k] === "object" && !Array.isArray(b[k]) && a[k] && typeof a[k] === "object") merge(a[k], b[k]); else a[k] = b[k]; } return a; }
const still = (D, el, az = 0, extra = {}) => ({ keys: [{ t: 0, D, el, az, yaw: 0, pitch: 0, roll: 0, ...extra }] });

// [name, tags, overrides]
const LIST = [
  // distance x tilt x heading, normal light, hand-held still
  ["d3_t10_h0_mat", "core", { cam: still(3, 55), slab: { tilt: 10, heading: 0 } }],
  ["d4_t10_h90_mat", "core", { cam: still(4, 50), slab: { tilt: 10, heading: 90 } }],
  ["d5_t10_h180_mat", "core", { cam: still(5, 50), slab: { tilt: 10, heading: 180 } }],
  ["d4_t0_mat", "core", { cam: still(4, 52), slab: { tilt: 0, yaw: 35 } }],
  ["d4_t18_h270_mat", "core", { cam: still(4, 48), slab: { tilt: 18, heading: 270, yaw: 5 } }],
  ["d5_t15_h45_wood", "core floor", { floor: "wood", cam: still(5, 45, 20), slab: { tilt: 15, heading: 45 } }],
  ["d3_t5_h135_concrete", "core floor", { floor: "concrete", cam: still(3, 60, -15), slab: { tilt: 5, heading: 135, yaw: 50 } }],
  ["d4_t12_h225_plain", "core floor", { floor: "plain", floorTint: [200, 196, 188], cam: still(4, 55, 10), slab: { tilt: 12, heading: 225 } }],
  ["d5_t8_h315_darkfloor", "floor hard", { floor: "dark", cam: still(5, 50), slab: { tilt: 8, heading: 315 } }],
  ["d4_t14_h60_carpet", "floor", { floor: "carpet", cam: still(4, 50, -30), slab: { tilt: 14, heading: 60, yaw: -10 } }],
  // camera height and pitch
  ["low_el30_d5", "pose", { cam: still(5, 30), slab: { tilt: 10, heading: 200 } }],
  ["high_el75_d3", "pose", { cam: still(3, 75), slab: { tilt: 12, heading: 30 } }],
  ["offcenter_d4", "pose", { cam: still(4, 50, 0, { yaw: 14, pitch: -12 }), slab: { tilt: 9, heading: 120 } }],
  ["roll15_d4", "pose", { cam: still(4, 50, 0, { roll: 15 }), slab: { tilt: 11, heading: 250 } }],
  // light
  ["dim_d4_mat", "light", { light: { level: 0.06 }, cam: still(4, 50), slab: { tilt: 10, heading: 30 } }],
  ["dim_d5_wood", "light", { floor: "wood", light: { level: 0.04, sun: 1.2, amb: 1.2 }, cam: still(5, 48), slab: { tilt: 13, heading: 160 } }],
  ["rake_lowcontrast_d4", "light hard", { light: { type: "side", sun: 3.2, amb: 0.35, el: 14, az: 90 }, cam: still(4, 50), slab: { tilt: 9, heading: 0, yaw: 0 } }],
  ["rake_lowcontrast_d5_conc", "light hard", { floor: "concrete", light: { type: "side", sun: 3.2, amb: 0.3, el: 18, az: -100 }, cam: still(5, 45), slab: { tilt: 12, heading: 90, yaw: 8 } }],
  ["overhead_d4", "light", { light: { type: "overhead", sun: 3, amb: 0.5, el: 85, az: 0 }, cam: still(4, 55), slab: { tilt: 10, heading: 300 } }],
  ["outdoor_sun_d5", "light", { floor: "concrete", light: { type: "outdoor", sun: 4, amb: 1.2, el: 55, az: 140, level: 3 }, cam: still(5, 50), slab: { tilt: 7, heading: 80 } }],
  ["expo_drift_d4", "light", { expo: { drift: 0.35, period: 1.6 }, cam: still(4, 50), slab: { tilt: 10, heading: 330 } }],
  ["sidelit_face_d4", "light hard", { light: { el: 25, az: 180, sun: 2.8, amb: 0.5 }, slab: { tilt: 8, heading: 0, yaw: 0, sideTint: [1.25, 1.25, 1.22] }, cam: still(4, 45) }],
  // motion
  ["shake_high_d4", "motion", { cam: { ...still(4, 50), shake: 2.6 }, light: { level: 0.3 }, slab: { tilt: 10, heading: 100 } }],
  ["approach_5to3", "motion", { cam: { keys: [{ t: 0, D: 5, el: 45, az: -10 }, { t: 0.6, D: 5, el: 45, az: -10 }, { t: 3.2, D: 3, el: 58, az: 10 }] }, slab: { tilt: 10, heading: 20 } }],
  ["pan_in_from_floor", "motion lock", { cam: { keys: [{ t: 0, D: 4, el: 50, az: 0, yaw: 32, pitch: 20 }, { t: 0.5, D: 4, el: 50, az: 0, yaw: 32, pitch: 20 }, { t: 1.8, D: 4, el: 50, az: 0, yaw: 0, pitch: 0 }] }, frames: 150, slab: { tilt: 10, heading: 200 } }],
  ["pan_out_back", "motion lock", { cam: { keys: [{ t: 0, D: 4, el: 50, az: 0 }, { t: 1.2, D: 4, el: 50, az: 0 }, { t: 2.0, D: 4, el: 50, az: 0, yaw: -40 }, { t: 2.8, D: 4, el: 50, az: 0, yaw: -40 }, { t: 3.6, D: 4, el: 50, az: 0 }] }, frames: 150, slab: { tilt: 10, heading: 60 } }],
  ["orbit_d4", "motion", { cam: { keys: [{ t: 0, D: 4, el: 50, az: -30 }, { t: 4, D: 4, el: 55, az: 30 }] }, slab: { tilt: 12, heading: 0 } }],
  // the ball
  ["ball_held_d4", "ball", { ball: { h: 2, dx: 0.05, dz: -0.05, arm: "other" }, cam: still(4, 50), slab: { tilt: 10, heading: 0 } }],
  ["ball_held_d3_low", "ball", { ball: { h: 1, dx: -0.08, dz: 0.05, arm: "self" }, cam: still(3, 55), slab: { tilt: 8, heading: 90 } }],
  ["ball_held_d5_high", "ball", { ball: { h: 3, dx: 0.1, dz: 0.08, arm: "other" }, cam: still(5, 40, 0, { pitch: 18 }), slab: { tilt: 12, heading: 200 } }],
  ["ball_drop_d4", "ball", { ball: { h: 1.5, dx: 0, dz: 0.05, drop: 2.2, arm: "self" }, cam: still(4, 50), slab: { tilt: 12, heading: 0 }, frames: 120 }],
  ["ball_held_dim", "ball light", { ball: { h: 2, dx: 0.05, dz: 0, arm: "other" }, light: { level: 0.07 }, cam: still(4, 50), slab: { tilt: 10, heading: 270 } }],
  ["ball_offslab_d4", "ball fp", { ball: { h: 1.5, dx: 0.75, dz: 0.2, arm: "other" }, cam: still(4, 50, 0, { yaw: -6 }), slab: { tilt: 10, heading: 0 } }],
  // things that might look like the ball (no ball in view)
  ["distract_tin_coin", "fp", { extras: [{ type: "tin", x: -0.6, z: -0.5 }, { type: "tin", x: 0.55, z: 0.3, lid: "black", r: 0.09 }, { type: "coin", x: 0.08, z: -0.05, onSlab: true }, { type: "sticker", x: 0.4, z: -0.6 }, { type: "coin", x: -0.3, z: 0.45 }], cam: still(4, 50), slab: { tilt: 10, heading: 150 } }],
  ["distract_floorball", "fp", { extras: [{ type: "floorball", x: 0.45, z: -0.35 }, { type: "floorball", x: -0.5, z: -0.9 }], cam: still(4, 55), slab: { tilt: 10, heading: 0 } }],
  ["distract_mat_circles", "fp", { extras: [{ type: "sticker", x: -0.3, z: -0.7, r: 0.04 }, { type: "sticker", x: 0.2, z: -0.9, r: 0.05 }, { type: "tin", x: 0.1, z: -1.4 }], cam: still(5, 45), slab: { tilt: 13, heading: 240 } }],
  // no slab in view
  ["noslab_clutter", "noslab", { slabPresent: false, extras: [{ type: "box", x: -0.8, z: -0.9, w: 1.0, h: 0.8, d: 0.7, rot: 20 }, { type: "paper", x: 0.3, z: 0.1, w: 0.71, d: 0.92, rot: 15 }, { type: "tin", x: -0.2, z: 0.5 }, { type: "stick", x: 0.4, z: -0.4, rot: 40 }], cam: still(4, 50) }],
  ["noslab_lookalike", "noslab hard", { slabPresent: false, floor: "wood", extras: [{ type: "rect", x: 0, z: 0, w: 0.42, d: 0.75, th: 0.07, pad: true, rot: 10 }, { type: "paper", x: 0.8, z: -0.3, w: 0.71, d: 0.92, rot: -20 }], cam: still(4, 50) }],
  ["noslab_base_only", "noslab", { slabPresent: false, baseOnly: true, floor: "concrete", cam: still(4, 50), slab: { tilt: 10 } }],
  // slab variations
  ["rect_slab_d4", "shape", { slab: { aspect: 1.03, tilt: 10, heading: 45 }, cam: still(4, 50) }],
  ["curved_slab_d4", "shape", { slab: { sag: 0.25, tilt: 11, heading: 135, yaw: 40 }, cam: still(4, 50) }],
  ["thick_lowview_d4", "shape hard", { slab: { thick: 1.15, tilt: 8, heading: 180, yaw: 0 }, cam: still(4, 35) }],
  ["lens_off_d4", "shape", { cam: { ...still(4, 50), fov: 70, k1: -0.03 }, slab: { tilt: 10, heading: 100 } }],
  ["ios_sign_noacc_d4", "sensor", { sensor: { iosSign: true, noAcc: true, bias: 0.5 }, cam: still(4, 50), slab: { tilt: 10, heading: 10 } }],
  // (new clips go at the end: a clip's random seed comes from its position in this list)
  // floor about as dark as the slab top (as in the reference photos): the far edges have almost no brightness step
  ["matchtone_mat_d4", "floor hard", { floor: "mat", floorTint: [92, 95, 90], cam: still(4, 50), slab: { tilt: 10, heading: 20 } }],
  ["matchtone_mat_d5_dim", "floor hard light", { floor: "mat", floorTint: [96, 98, 92], light: { level: 0.08 }, cam: still(5, 45), slab: { tilt: 14, heading: 160 } }],
  ["matchtone_concrete_d4", "floor hard", { floor: "concrete", floorTint: [98, 100, 94], cam: still(4, 55, 25), slab: { tilt: 7, heading: 290 } }],
  // Chrome on Android (scene.js sensorQuirks): readings rounded to 0.1 m/s^2, a little wrist tremor; with a gyroscope,
  // `acceleration` is a separate sensor read up to one event earlier; without one, Chrome derives it with a light low-pass
  ["android_lag_d4", "sensor", { sensor: { trem: 0.08, accLag: 1 / 60, accLagRand: true, round: 0.1 }, cam: still(4, 50, 15), slab: { tilt: 12, heading: 250 } }],
  ["android_nogyro_d4", "sensor", { sensor: { trem: 0.08, accLpf: 0.5, round: 0.1, noGyro: true }, cam: still(4, 50), slab: { tilt: 10, heading: 140 } }],
  // Gyro conventions and faults (scene.js gyroQuirks) and translation-heavy hand motion (scene.js cam.sway), added in
  // the review of b14. WebKit, Chromium and Gecko all report rotationRate alpha/beta/gamma about the x/y/z device axes
  // (the current W3C draft agrees; the clips above use the 2016 naming alpha = z); WebKit reports `interval` in seconds.
  ["ios_gyro_real_d4", "sensor gyro", { sensor: { gyroOrder: "xyz", gyroIvSec: true }, cam: still(4, 50, -10), slab: { tilt: 11, heading: 40 } }],
  ["android_gyro_real_d4", "sensor gyro", { sensor: { gyroOrder: "xyz", trem: 0.08, accLag: 1 / 60, accLagRand: true, round: 0.1 }, cam: { ...still(4, 48, 10), shake: 1.4 }, slab: { tilt: 9, heading: 300 } }],
  ["gyro_flip_d4", "sensor gyro", { sensor: { gyroSign: -1 }, cam: still(4, 52), slab: { tilt: 10, heading: 170 } }],
  ["gyro_rad_d4", "sensor gyro", { sensor: { gyroRad: true }, cam: still(4, 50, 5), slab: { tilt: 12, heading: 80 } }],
  ["gyro_bias_d4", "sensor gyro", { sensor: { gyroBias: [1.2, -0.8, 1.0] }, cam: still(4, 50), slab: { tilt: 10, heading: 220 } }],
  ["gyro_flipbeta_d4", "sensor gyro", { sensor: { gyroAxisFlip: "beta" }, cam: still(4, 50, -5), slab: { tilt: 13, heading: 120 } }],
  // standing body sway (mostly travel, the phone re-aimed to keep the slab in place) after 2 s of ordinary holding
  ["sway_fixate_d4", "motion gyro", { cam: { ...still(4, 50), sway: { amp: 0.03, f0: 0.1, f1: 0.5, fix: 1, t0: 2 } }, frames: 150, slab: { tilt: 10, heading: 30 } }],
  // stress: a steady hand travelling while aimed at a point twice as far as the slab (image motion opposite to the turn)
  ["sway_far_d4", "motion gyro hard", { cam: { ...still(4, 50), shake: 0.6, sway: { amp: 0.04, f0: 0.15, f1: 0.6, fix: 2 } }, frames: 150, slab: { tilt: 10, heading: 260 } }],
  // slow walking bob after 1.5 s of holding, slab kept in place
  ["walk_d4", "motion gyro", { cam: { ...still(4, 50), sway: { amp: 0.07, f0: 0.8, f1: 2, fix: 1, vert: 1.5, t0: 1.5 } }, frames: 150, slab: { tilt: 11, heading: 150 } }],
  // camera frames reaching the page ~2 frames after the motion events for the same moment (phone camera pipelines)
  ["gyro_lead_d4", "sensor gyro", { sensor: { gyroLead: 0.067 }, cam: still(4, 50, 10), slab: { tilt: 10, heading: 60 } }],
  // Chrome on Android naming with the hand's sway mostly a slow turn about the vertical (couples the phone's y and z rates)
  ["android_gyro_yaw_d4", "sensor gyro hard", { sensor: { gyroOrder: "xyz", round: 0.1 }, cam: { ...still(4, 45, -5), shake: 0.6, wyaw: { amp: 0.8, f0: 0.2, f1: 1 } }, slab: { tilt: 10, heading: 330 } }],
  // the same hand with the naming the clips above use (the reference for the one before)
  ["gyro_yaw_d4", "sensor gyro", { sensor: { round: 0.1 }, cam: { ...still(4, 45, -5), shake: 0.6, wyaw: { amp: 0.8, f0: 0.2, f1: 1 } }, slab: { tilt: 10, heading: 330 } }],
  // round things behind the slab, so they appear above it in the image (the real phone fired on something with no ball in view)
  ["fp_tin_behind_d4", "fp", { extras: [{ type: "tin", x: 0.05, z: -1.0 }, { type: "tin", x: -0.45, z: -1.6, lid: "black", r: 0.09 }], cam: still(4, 48), slab: { tilt: 10, heading: 20 } }],
  ["fp_lid_sticker_behind_d5", "fp", { extras: [{ type: "sticker", x: 0.1, z: -0.8, r: 0.07 }, { type: "coin", x: -0.2, z: -1.2, r: 0.05 }, { type: "tin", x: 0.4, z: -2.2, r: 0.14 }], cam: still(5, 42), slab: { tilt: 12, heading: 200 } }],
  ["fp_floorball_behind_d4", "fp", { extras: [{ type: "floorball", x: 0.0, z: -0.9 }, { type: "floorball", x: 0.3, z: -1.5 }], cam: still(4, 50), slab: { tilt: 9, heading: 60 } }],
];

function clips(filter) {
  const out = LIST.map(([name, tags, o], i) => {
    const s = merge(base(), JSON.parse(JSON.stringify(o)));
    s.name = name; s.tags = tags.split(" "); s.seed = 1000 + i * 17;
    if (o.cam && !o.cam.keys) s.cam.keys = base().cam.keys;
    return s;
  });
  if (!filter) return out;
  const f = filter.split(",");
  return out.filter((c) => f.some((x) => c.name === x || c.tags.includes(x) || (x.endsWith("*") && c.name.startsWith(x.slice(0, -1)))));
}
module.exports = { clips };
