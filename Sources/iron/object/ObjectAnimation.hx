package iron.object;

import iron.object.Animation.Animparams;

import kha.arrays.Float32Array;
import kha.FastFloat;
import kha.arrays.Uint32Array;
import iron.math.Vec4;
import iron.math.Mat4;
import iron.math.Quat;
import iron.data.SceneFormat;

class ObjectAnimation extends Animation {

	public var object: Object;
	public var oactions: Array<TSceneFormat>;
	var oaction: TObj;
	var s0: FastFloat = 0.0;
	var bezierFrameIndex = -1;

	var updateAnimation: Float32Array->Void;

	public var transformArr: Float32Array;

	public function new(object: Object, oactions: Array<TSceneFormat>) {
		this.object = object;
		this.oactions = oactions;
		isSkinned = false;
		super();
	}

	function getAction(action: String): TObj {
		for (a in oactions) if (a != null && a.objects[0].name == action) return a.objects[0];
		return null;
	}

	override public function play(action = "", onComplete: Void->Void = null, blendTime = 0.0, speed = 1.0, loop = true) {
		super.play(action, onComplete, blendTime, speed, loop);
		if (this.action == "" && oactions[0] != null) this.action = oactions[0].objects[0].name;
		oaction = getAction(this.action);
		if (oaction != null) {
			isSampled = oaction.sampled != null && oaction.sampled;
		}
	}

	override public function update(delta: FastFloat) {
		trace("objet animation update loop");
		if (!object.visible || object.culled) return;

		#if arm_debug
		Animation.beginProfile();
		#end

		if(transformArr == null) transformArr = new Float32Array(26);

		//super.update(delta);
		super.updateNew(delta);
		if (paused) return;
		trace(updateAnimation);
		if(updateAnimation == null) return;
		trace("update animation not null");
		if (!isSkinned) updateObjectAnimNew();

		#if arm_debug
		Animation.endProfile();
		#end
	}

	public function animationLoop(f: Float32Array->Void){
		
		trace("setting update loop");
		trace(updateAnimation);
		updateAnimation = f;
		trace(updateAnimation);
	}

	function updateObjectAnim() {
		updateTransformAnim(oaction.anim, object.transform);
		object.transform.buildMatrix();
	}

	function updateObjectAnimNew() {
		trace("update object anim new");
		updateAnimation(transformArr);
		updateTransformAnimNew(transformArr, object.transform);
		object.transform.buildMatrix();
	}

	override public function updateActionTrack(actionParam: Animparams) {
		if(actionParam.paused) return;
		oaction = getAction(actionParam.action);
		updateTrackNew(oaction.anim, actionParam);

	}

	function updateAnimSampledObjNew(anim: TAnimation, transformArr: Float32Array, actionParam: Animparams) {

		for (track in anim.tracks) {
			trace("setting values");
			trace(track.target);
			trace(transformArr);
			var sign = actionParam.speed > 0 ? 1 : -1;

			var t = actionParam.time;
			//t = t < 0 ? 0.1 : t;

			var ti = actionParam.offset;
			//ti = ti < 0 ? 1 : ti;

			var t1 = track.frames[ti] * frameTime;
			var t2 = track.frames[ti + sign] * frameTime;
			var v1 = track.values[ti];
			var v2 = track.values[ti + sign];

			var value = interpolateLinear(t, t1, t2, v1, v2);

			if(value == null) continue;
			trace("setting values 2");
			switch (track.target) {

				case "xloc": transformArr.set(0, value);
				case "yloc": transformArr.set(1, value);
				case "zloc": transformArr.set(2, value);
				case "xrot": transformArr.set(3, value);
				case "yrot": transformArr.set(4, value);
				case "zrot": transformArr.set(5, value);
				case "qwrot": transformArr.set(6, value); 
				case "qxrot": transformArr.set(7, value);
				case "qyrot": transformArr.set(8, value);
				case "qzrot": transformArr.set(9, value);
				case "xscl": transformArr.set(10, value);
				case "yscl": transformArr.set(11, value);
				case "zscl": transformArr.set(12, value);
				// Delta
				case "dxloc": transformArr.set(13, value);
				case "dyloc": transformArr.set(14, value);
				case "dzloc": transformArr.set(15, value);
				case "dxrot": transformArr.set(16, value);
				case "dyrot": transformArr.set(17, value);
				case "dzrot": transformArr.set(18, value);
				case "dqwrot": transformArr.set(19, value);
				case "dqxrot": transformArr.set(20, value);
				case "dqyrot": transformArr.set(21, value);
				case "dqzrot": transformArr.set(22, value);
				case "dxscl": transformArr.set(23, value); 
				case "dyscl": transformArr.set(24, value);
				case "dzscl": transformArr.set(25, value);
			}
			trace("setting values 3");
		}
	}

	public function sampleAction(actionParam: Animparams, transformArr: Float32Array){
		trace("sampling action");
		var objanim = getAction(actionParam.action);
			
		updateAnimSampledObjNew(objanim.anim, transformArr, actionParam);
	}

	public function blendActionObject(transformArr1: Float32Array, transformArr2: Float32Array, transformArrRes: Float32Array, factor: FastFloat ) {

		for(i in 0...transformArrRes.length){
			transformArrRes.set(i, (1.0 - factor) * transformArr1.get(i) + factor * transformArr2.get(i));
		}
		
	}

	inline function interpolateLinear(t: FastFloat, t1: FastFloat, t2: FastFloat, v1: FastFloat, v2: FastFloat): FastFloat {
		var s = (t - t1) / (t2 - t1);
		return (1.0 - s) * v1 + s * v2;
	}

	// inline function interpolateTcb(): FastFloat { return 0.0; }

	override function isTrackEnd(track: TTrack): Bool {
		return speed > 0 ?
			frameIndex >= track.frames.length - 2 :
			frameIndex <= 0;
	}

	inline function checkFrameIndexT(frameValues: Uint32Array, t: FastFloat): Bool {
		return speed > 0 ?
			frameIndex < frameValues.length - 2 && t > frameValues[frameIndex + 1] * frameTime :
			frameIndex > 1 && t > frameValues[frameIndex - 1] * frameTime;
	}

	@:access(iron.object.Transform)
	function updateTransformAnim(anim: TAnimation, transform: Transform) {
		if (anim == null) return;

		var total = anim.end * frameTime - anim.begin * frameTime;

		if (anim.has_delta) {
			var t = transform;
			if (t.dloc == null) {
				t.dloc = new Vec4();
				t.drot = new Quat();
				t.dscale = new Vec4();
			}
			t.dloc.set(0, 0, 0);
			t.dscale.set(0, 0, 0);
			t._deulerX = t._deulerY = t._deulerZ = 0.0;
		}
		trace("num tracks =");
		trace(anim.tracks.length);
		for (track in anim.tracks) {

			if (frameIndex == -1) rewind(track);
			var sign = speed > 0 ? 1 : -1;

			// End of current time range
			var t = time + anim.begin * frameTime;
			while (checkFrameIndexT(track.frames, t)) frameIndex += sign;

			// No data for this track at current time
			if (frameIndex >= track.frames.length) continue;

			// End of track
			if (time > total) {
				if (onComplete != null) onComplete();
				if (loop) rewind(track);
				else {
					frameIndex -= sign;
					paused = true;
				}
				return;
			}

			var ti = frameIndex;
			var t1 = track.frames[ti] * frameTime;
			var t2 = track.frames[ti + sign] * frameTime;
			var v1 = track.values[ti];
			var v2 = track.values[ti + sign];

			var value = interpolateLinear(t, t1, t2, v1, v2);

			switch (track.target) {
				case "xloc": transform.loc.x = value;
				case "yloc": transform.loc.y = value;
				case "zloc": transform.loc.z = value;
				case "xrot": transform.setRotation(value, transform._eulerY, transform._eulerZ);
				case "yrot": transform.setRotation(transform._eulerX, value, transform._eulerZ);
				case "zrot": transform.setRotation(transform._eulerX, transform._eulerY, value);
				case "qwrot": transform.rot.w = value;
				case "qxrot": transform.rot.x = value;
				case "qyrot": transform.rot.y = value;
				case "qzrot": transform.rot.z = value;
				case "xscl": transform.scale.x = value;
				case "yscl": transform.scale.y = value;
				case "zscl": transform.scale.z = value;
				// Delta
				case "dxloc": transform.dloc.x = value;
				case "dyloc": transform.dloc.y = value;
				case "dzloc": transform.dloc.z = value;
				case "dxrot": transform._deulerX = value;
				case "dyrot": transform._deulerY = value;
				case "dzrot": transform._deulerZ = value;
				case "dqwrot": transform.drot.w = value;
				case "dqxrot": transform.drot.x = value;
				case "dqyrot": transform.drot.y = value;
				case "dqzrot": transform.drot.z = value;
				case "dxscl": transform.dscale.x = value;
				case "dyscl": transform.dscale.y = value;
				case "dzscl": transform.dscale.z = value;
			}
		}
	}

	@:access(iron.object.Transform)
	function updateTransformAnimNew(transformArr: Float32Array, transform: Transform) {

		trace("setting object transform new");

		var t = transform;
		if (t.dloc == null) {
			t.dloc = new Vec4();
			t.drot = new Quat();
			t.dscale = new Vec4();
		}
		t.dloc.set(0, 0, 0);
		t.dscale.set(0, 0, 0);
		t._deulerX = t._deulerY = t._deulerZ = 0.0;

		transform.loc.x = transformArr.get(0);
		transform.loc.y = transformArr.get(1);
		transform.loc.z = transformArr.get(2);
		transform.setRotation(transformArr.get(3), transform._eulerY, transform._eulerZ);
		transform.setRotation(transform._eulerX, transformArr.get(4), transform._eulerZ);
		transform.setRotation(transform._eulerX, transform._eulerY, transformArr.get(5));
		transform.rot.w = transformArr.get(6);
		transform.rot.x = transformArr.get(7);
		transform.rot.y = transformArr.get(8);
		transform.rot.z = transformArr.get(9);
		transform.scale.x = transformArr.get(10);
		transform.scale.y = transformArr.get(11);
		transform.scale.z = transformArr.get(12);
			// Delta
		transform.dloc.x = transformArr.get(13);
		transform.dloc.y = transformArr.get(14);
		transform.dloc.z = transformArr.get(15);
		transform._deulerX = transformArr.get(16);
		transform._deulerY = transformArr.get(17);
		transform._deulerZ = transformArr.get(18);
		transform.drot.w = transformArr.get(19);
		transform.drot.x = transformArr.get(20);
		transform.drot.y = transformArr.get(21);
		transform.drot.z = transformArr.get(22);
		transform.dscale.x = transformArr.get(23);
		transform.dscale.y = transformArr.get(24);
		transform.dscale.z = transformArr.get(25);

		trace("setting object transform new 2");
		
	}

	override public function totalFrames(): Int {
		if (oaction == null || oaction.anim == null) return 0;
		return oaction.anim.end - oaction.anim.begin;
	}
}
