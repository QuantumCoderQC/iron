package iron.object;

import haxe.ds.Vector;
import iron.math.Vec3;
import iron.math.Vec2;
import kha.FastFloat;
import kha.arrays.Uint32Array;
import iron.math.Vec4;
import iron.math.Mat4;
import iron.math.Quat;
import iron.data.SceneFormat;

class Animation {

	public var isSkinned: Bool;
	public var isSampled: Bool;
	public var action = "";
	#if arm_skin
	public var armature: iron.data.Armature; // Bone
	#end

	// Lerp
	static var m1 = Mat4.identity();
	static var m2 = Mat4.identity();
	static var vpos = new Vec4();
	static var vpos2 = new Vec4();
	static var vscl = new Vec4();
	static var vscl2 = new Vec4();
	static var q1 = new Quat();
	static var q2 = new Quat();
	static var q3 = new Quat();
	static var vp = new Vec4();
	static var vs = new Vec4();

	public var time: FastFloat = 0.0;
	public var speed: FastFloat = 1.0;
	public var loop = true;
	public var frameIndex = 0;
	public var onComplete: Void->Void = null;
	public var paused = false;
	var frameTime: FastFloat = 1 / 60;

	var blendTime: FastFloat = 0.0;
	var blendCurrent: FastFloat = 0.0;
	var blendFactor: FastFloat = 0.0;

	var lastFrameIndex = -1;
	var markerEvents: Map<Animparams, Map<String, Array<Void->Void>>> = null;

	public var activeActions: Map<String, Animparams> = null;

	function new() {
		Scene.active.animations.push(this);
		if (Scene.active.raw.frame_time != null) {
			frameTime = Scene.active.raw.frame_time;
		}
		play();
	}

	public function play(action = "", onComplete: Void->Void = null, blendTime = 0.0, speed = 1.0, loop = true) {
		if (blendTime > 0) {
			this.blendTime = blendTime;
			this.blendCurrent = 0.0;
			frameIndex = 0;
			time = 0.0;
		}
		else frameIndex = -1;
		this.action = action;
		this.onComplete = onComplete;
		this.speed = speed;
		this.loop = loop;
		paused = false;
	}

	public function pause() {
		paused = true;
	}

	public function resume() {
		paused = false;
	}

	public function remove() {
		Scene.active.animations.remove(this);
	}

	public function updateActionTrack(actionParam: Animparams){
		return;
	}

	public function update(delta: FastFloat) {
		if(activeActions == null) return;

		for(actionParam in activeActions){
			if (actionParam.paused || actionParam.speed == 0.0) {
				continue;
			}
			else {
				actionParam.timeOld = actionParam.time;
				actionParam.offsetOld = actionParam.offset;
				actionParam.setTimeOnly(actionParam.time + delta * actionParam.speed);
				updateActionTrack(actionParam);
			}
		}
		
	}

	public function registerAction(actionID: String, actionParam: Animparams){
		if (activeActions == null) activeActions = new Map();
		activeActions.set(actionID, actionParam);
	}

	public function deRegisterAction(actionID: String) {
		if (activeActions == null) return;
		if(activeActions.exists(actionID)) activeActions.remove(actionID);
		
	}

	inline function isTrackEnd(track: TTrack, frameIndex: Int, speed: FastFloat): Bool {
		return speed > 0 ?
			frameIndex >= track.frames.length - 1 :
			frameIndex <= 0;
	}

	inline function checkFrameIndex(frameValues: Uint32Array, time: FastFloat, frameIndex: Int, speed: FastFloat): Bool {
		return speed > 0 ?
			((frameIndex + 1) < frameValues.length && time > frameValues[frameIndex + 1] * frameTime) :
			((frameIndex - 1) > -1 && time < frameValues[frameIndex - 1] * frameTime);
	}

	function rewind(track: TTrack) {
		frameIndex = speed > 0 ? 0 : track.frames.length - 1;
		time = track.frames[frameIndex] * frameTime;
	}

	function updateTrack(anim: TAnimation, actionParam: Animparams) {

		var time = actionParam.time;
		var frameIndex = actionParam.offset;
		var speed = actionParam.speed;

		var track = anim.tracks[0];

		if (frameIndex == -1) {
			actionParam.timeOld = actionParam.time;
			actionParam.offsetOld = actionParam.offset;
			frameIndex = speed > 0 ? 0 : track.frames.length - 1;
			time = track.frames[frameIndex] * frameTime;
		}

		// Move keyframe
		var sign = speed > 0 ? 1 : -1;
		while (checkFrameIndex(track.frames, time, frameIndex, speed)) frameIndex += sign;

		// Marker events
		if (markerEvents != null && anim.marker_names != null && frameIndex != lastFrameIndex) {
			if(markerEvents.get(actionParam) != null){
				for (i in 0...anim.marker_frames.length) {
					if (frameIndex == anim.marker_frames[i]) {
						var marketAct = markerEvents.get(actionParam);
						var ar = marketAct.get(anim.marker_names[i]);
						if (ar != null) for (f in ar) f();
					}
				}
				lastFrameIndex = frameIndex;
			}
		}

		// End of track
		if (isTrackEnd(track, frameIndex, speed)) {
			if (actionParam.loop) {
				actionParam.offsetOld = frameIndex;
				frameIndex = speed > 0 ? 0 : track.frames.length - 1;
				time = track.frames[frameIndex] * frameTime;
			}
			else {
				frameIndex -= sign;
				actionParam.paused = true;
			}
			if (actionParam.onComplete != null) for(func in actionParam.onComplete){ func();};
		}

		actionParam.setFrameOffsetOnly(frameIndex);
		actionParam.speed = speed;
		actionParam.setTimeOnly(time);

	}

	public function notifyOnMarker(actionParam: Animparams, name: String, onMarker: Void->Void) {
		if (markerEvents == null) markerEvents = new Map();

		var markerAct = markerEvents.get(actionParam);
		if(markerAct == null){
			markerAct = new Map();
			markerEvents.set(actionParam, markerAct);
		}

		var ar = markerAct.get(name);
		if (ar == null) {
			ar = [];
			markerAct.set(name, ar);
		}
		ar.push(onMarker);
	}

	public function removeMarker(actionParam: Animparams, name: String, onMarker: Void->Void) {
		var markerAct = markerEvents.get(actionParam);
		if(markerAct == null) return;

		markerAct.get(name).remove(onMarker);
	}

	public function currentFrame(): Int {
		return Std.int(time / frameTime);
	}

	public function getTotalFrames(actionParam: Animparams): Int {
		return 0;
	}

	public static function getBlend2DWeights(actionCoords: Array<Vec2>, sampleCoords: Vec2): Vec3 {
		var weights = new Vector<Float>(3);
		var tempWeights = new Vector<Float>(2);

		// Gradient Band Interpolation
		for (i in 0...3){

			var v1 = new Vec2().setFrom(sampleCoords).sub(actionCoords[i]);
			var k = 0;
			for (j in 0...3){
				if (i == j) continue;
				var v2 = new Vec2().setFrom(actionCoords[j]).sub(actionCoords[i]);
				var len = new Vec2().setFrom(v2).dot(v2);
				var w = 1.0 - ((new Vec2().setFrom(v1).dot(v2)) / len);

				w = w < 0 ? 0 : w > 1.0 ? 1.0 : w;
				tempWeights.set(k, w);
				k++;		
			}

			weights.set(i, Math.min(tempWeights.get(0), tempWeights.get(1)));
		}

		var res = new Vec3(weights.get(0), weights.get(1), weights.get(2));

		res.mult(1.0 / (res.x + res.y + res.z));

		return res;
	}

	#if arm_debug
	public static var animationTime = 0.0;
	static var startTime = 0.0;

	static function beginProfile() {
		startTime = kha.Scheduler.realTime();
	}
	static function endProfile() {
		animationTime += kha.Scheduler.realTime() - startTime;
	}
	public static function endFrame() {
		animationTime = 0;
	}
	#end
}

class Animparams {

	public inline function new(action: String, speed: FastFloat = 1.0, loop: Bool = true, onComplete: Array<Void -> Void> = null) {

		this.action = action;
		this.speed = speed;
		this.loop = loop;
		this.onComplete = onComplete;
	}

	public var action(default, null): String;
	public var time(default, null): FastFloat = 0.0;
	public var offset(default, null): Int = 0; // Frames to offset
	public var speed: FastFloat; // Speed of the animation
	public var loop: Bool;
	public var paused: Bool = false;
	public var onComplete: Array<Void -> Void>;
	public var timeOld: FastFloat = 0.0;
	public var offsetOld: Int = 0;

	public inline function setFrameOffset(frameOffset: Int){
		this.offset = frameOffset;
		this.time = Scene.active.raw.frame_time * offset;
	}

	public inline function setTimeOffset(timeOffset: FastFloat){
		this.time = timeOffset;
		var ftime: FastFloat = Scene.active.raw.frame_time;
		this.offset = Std.int(time / ftime);
	}

	public inline function restartAction() {

		this.setFrameOffset(0);
		paused = false;	
	}

	public function notifyOnComplete(onComplete: Void -> Void) {
		if(this.onComplete == null) this.onComplete = [];
		this.onComplete.push(onComplete);
		
	}

	public function removeOnComplete(onComplete: Void -> Void) {
		this.onComplete.remove(onComplete);
	}

	public inline function setTimeOnly(time: FastFloat) {

		this.time = time;		
	}

	public inline function setFrameOffsetOnly(frame: Int) {

		this.offset = frame;		
	}
}
