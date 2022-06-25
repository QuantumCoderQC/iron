package iron.object;

import iron.object.Animation.ActionSampler;
#if arm_skin

import kha.FastFloat;
import kha.arrays.Float32Array;
import iron.math.Vec4;
import iron.math.Mat4;
import iron.math.Quat;
import iron.data.MeshData;
import iron.data.SceneFormat;
import iron.data.Armature;
import iron.data.Data;
import iron.math.Ray;

class BoneAnimation extends Animation {

	public static var skinMaxBones = 128;

	// Skinning
	public var object: MeshObject;
	public var data: MeshData;
	public var skinBuffer: Float32Array;

	var updateAnimation: Array<Mat4>->Void = null;

	var skeletonBones: Array<TObj> = null;
	var skeletonMats: Array<Mat4> = null;
	//var skeletonBonesBlend: Array<TObj> = null;
	var absMats: Array<Mat4> = null;
	var applyParent: Array<Bool> = null;
	var matsFast: Array<Mat4> = [];
	var matsFastSort: Array<Int> = [];
	var matsFastBlend: Array<Mat4> = [];
	var matsFastBlendSort: Array<Int> = [];

	var rootMotion: TObj = null;
	var rootMotionVelocity: Vec4 = null;
	var rootMotionIndex: Null<Int> = null;
	var rootMotionLockX: Bool = false;
	var rootMotionLockY: Bool = false;
	var rootMotionLockZ: Bool = false;
	var oldPos: Vec4 = null;
	var oldPosWorld: Vec4 = null;
	var oldTransform: Mat4 = null;

	var delta: FastFloat = 0;

	var boneChildren: Map<String, Array<Object>> = null; // Parented to bone

	var constraintTargets: Array<Object> = null;
	var constraintTargetsI: Array<Mat4> = null;
	var constraintMats: Map<TObj, Mat4> = null;
	var relativeBoneConstraints: Bool = false;

	static var m = Mat4.identity(); // Skinning matrix
	static var m1 = Mat4.identity();
	static var m2 = Mat4.identity();
	static var bm = Mat4.identity(); // Absolute bone matrix
	static var wm = Mat4.identity();
	static var vpos = new Vec4();
	static var vscl = new Vec4();
	static var q1 = new Quat();
	static var q2 = new Quat();
	static var q3 = new Quat();
	static var q4 = new Quat();
	static var vpos2 = new Vec4();
	static var vpos3 = new Vec4();
	static var vscl2 = new Vec4();
	static var vscl3 = new Vec4();
	static var v1 = new Vec4();
	static var v2 = new Vec4();

	public function new(armatureUid: Int) {
		super();
		this.isSampled = false;
		for (a in Scene.active.armatures) {
			if (a.uid == armatureUid) {
				this.armature = a;
				break;
			}
		}
	}

	public inline function getNumBones(): Int {
		if (skeletonBones == null) return 0;
		return skeletonBones.length;
	}

	public function setSkin(mo: MeshObject) {
		this.object = mo;
		this.data = mo != null ? mo.data : null;
		this.isSkinned = data != null ? data.isSkinned : false;
		if (this.isSkinned) {
			var boneSize = 12; // Dual-quat skinning + scaling
			this.skinBuffer = new Float32Array(skinMaxBones * boneSize);
			for (i in 0...this.skinBuffer.length) this.skinBuffer[i] = 0;
			// Rotation is already applied to skin at export
			object.transform.rot.set(0, 0, 0, 1);
			object.transform.buildMatrix();

			var refs = mo.parent.raw.bone_actions;
			if (refs != null && refs.length > 0) {
				Data.getSceneRaw(refs[0], function(action: TSceneFormat) { play(action.name); });
			}
		}
		if (object.parent.raw.relative_bone_constraints) relativeBoneConstraints = true;

	}

	public function addBoneChild(bone: String, o: Object) {
		if (boneChildren == null) boneChildren = new Map();
		var ar = boneChildren.get(bone);
		if (ar == null) {
			ar = [];
			boneChildren.set(bone, ar);
		}
		ar.push(o);
	}
	
	public function removeBoneChild(bone: String, o: Object) {
		if (boneChildren != null) {
			var ar = boneChildren.get(bone);
			if (ar != null) ar.remove(o);
		}
	}
 
	@:access(iron.object.Transform)
	function updateBoneChildren(bone: TObj, bm: Mat4) {
		var ar = boneChildren.get(bone.name);
		if (ar == null) return;
		for (o in ar) {
			var t = o.transform;
			if (t.boneParent == null) t.boneParent = Mat4.identity();
			if (o.raw.parent_bone_tail != null) {
				if (o.raw.parent_bone_connected || isSkinned) {
					var v = o.raw.parent_bone_tail;
					t.boneParent.initTranslate(v[0], v[1], v[2]);
					t.boneParent.multmat(bm);
				}
				else {
					var v = o.raw.parent_bone_tail_pose;
					t.boneParent.setFrom(bm);
					t.boneParent.translate(v[0], v[1], v[2]);
				}
			}
			else t.boneParent.setFrom(bm);
			t.buildMatrix();
		}
	}

	public function setRootMotion(bone: TObj, lockX: Bool = false, lockY: Bool = false, lockZ: Bool = false){
		rootMotion = bone;
		rootMotionIndex = null;
		oldPos = null;
		rootMotionLockX	= lockX;
		rootMotionLockY	= lockY;
		rootMotionLockZ	= lockZ;
		rootMotionVelocity = new Vec4();
	}

	public function getRootMoptionVelocity(): Vec4 {
		return rootMotionVelocity;
	}

	function numParents(b: TObj): Int {
		var i = 0;
		var p = b.parent;
		while (p != null) {
			i++;
			p = p.parent;
		}
		return i;
	}

	function setMats() {
		while (matsFast.length < skeletonBones.length) {
			matsFast.push(Mat4.identity());
			matsFastSort.push(matsFastSort.length);
		}
		// Calc bones with 0 parents first
		matsFastSort.sort(function(a, b) {
			var i = numParents(skeletonBones[a]);
			var j = numParents(skeletonBones[b]);
			return i < j ? -1 : i > j ? 1 : 0;
		});

	}

	function setAction(action: String) {
		if (isSkinned) {
			skeletonBones = data.geom.actions.get(action);
			skeletonMats = data.geom.mats.get(action);
		}
		else {
			armature.initMats();
			var a = armature.getAction(action);
			skeletonBones = a.bones;
			skeletonMats = a.mats;
		}
		setMats();
	}

	override public function play(action = "", onComplete: Void->Void = null, blendTime = 0.2, speed = 1.0, loop = true) {
		super.play(action, onComplete, blendTime, speed, loop);
		if (action != "") {
			setAction(action);
			var tempAnimParam = new ActionSampler(action);
			registerAction("tempAction", tempAnimParam);
			updateAnimation = function(mats){
				sampleAction(tempAnimParam, mats);
			}
		}
	}

	public function initMatsEmpty(): Array<Mat4> {

		var mats = [];
		for(i in 0...skeletonMats.length) mats.push(Mat4.identity());
		return mats;
	}

	override public function update(delta: FastFloat) {
		this.delta = delta;
		if (!isSkinned && skeletonBones == null) setAction(armature.actions[0].name);
		if (object != null && (!object.visible || object.culled)) return;
		if (skeletonBones == null || skeletonBones.length == 0) return;

		#if arm_debug
		Animation.beginProfile();
		#end

		super.update(delta);
		if(updateAnimation != null) {
			
			updateAnimation(skeletonMats);
		}

		updateConstraints();
		// Do forward kinematics and inverse kinematics here
		if (onUpdates != null) {
			var i = 0;
			var l = onUpdates.length;
			while (i < l) {
				onUpdates[i]();
				l <= onUpdates.length ? i++ : l = onUpdates.length;
			}
		}

		// Calc absolute bones
		for (i in 0...skeletonBones.length) {
			// Take bones with 0 parents first
			multParent(matsFastSort[i], matsFast, skeletonBones, skeletonMats);
		}
		if (isSkinned) updateSkinGpu();
		else updateBonesOnly();

		#if arm_debug
		Animation.endProfile();
		#end
	}

	function multParent(i: Int, fasts: Array<Mat4>, bones: Array<TObj>, mats: Array<Mat4>) {
		var f = fasts[i];
		if (applyParent != null && !applyParent[i]) {
			f.setFrom(mats[i]);
			return;
		}
		var p = bones[i].parent;
		var bi = getBoneIndex(p, bones);
		(p == null || bi == -1) ? f.setFrom(mats[i]) : f.multmats(fasts[bi], mats[i]);
	}

	public function evaluateRootMotion(actionMats: Array<Mat4>): Vec4{
		rootMotionIndex = getBoneIndex(rootMotion);
		var scl = object.parent.transform.scale;
		var newPos = new Vec4().setFrom(getWorldMat(rootMotion, actionMats).getLoc());

		if(oldPos == null) {
			oldPos = new Vec4().setFrom(getBoneMat(rootMotion, actionMats).getLoc());
			return rootMotionVelocity;
		}

		actionMats[rootMotionIndex]._30 = oldPos.x;
		actionMats[rootMotionIndex]._31 = oldPos.y;
		actionMats[rootMotionIndex]._32 = oldPos.z;

		newPos = multVecs(newPos, scl);
		rootMotionVelocity.setFrom(newPos);
		return new Vec4().setFrom(rootMotionVelocity);
		
	}


	inline function multVecs(vec1: Vec4, vec2: Vec4): Vec4 {
		var res = new Vec4().setFrom(vec1);
		res.x *= vec2.x;
		res.y *= vec2.y;
		res.z *= vec2.z;
		res.w *= vec2.w;

		return res;

	}

	public function getRootMotionBone(): TObj{
		return rootMotion;
	}

	function multParents(m: Mat4, i: Int, bones: Array<TObj>, mats: Array<Mat4>) {
		var bone = bones[i];
		var p = bone.parent;
		while (p != null) {
			var i = getBoneIndex(p, bones);
			if (i == -1) continue;
			m.multmat(mats[i]);
			p = p.parent;
		}
	}

	function getConstraintsFromScene(cs: Array<TConstraint>) {
		// Init constraints
		if (constraintTargets == null) {
			constraintTargets = [];
			constraintTargetsI = [];
			for (c in cs) {
				var o = Scene.active.getChild(c.target);
				constraintTargets.push(o);
				var m: Mat4 = null;
				if (o != null) {
					m = Mat4.identity().setFrom(o.transform.world);
					m.getInverse(m);
				}
				constraintTargetsI.push(m);
			}
			constraintMats = new Map();
		}
	}

	function getConstraintsFromParentRelative(cs: Array<TConstraint>) {
		// Init constraints
		if (constraintTargets == null) {
			constraintTargets = [];
			constraintTargetsI = [];
			// MeshObject -> ArmatureObject -> Collection/Empty
			var conParent = object.parent.parent;
			if (conParent == null) return;
			for (c in cs) {
				var o = conParent.getChild(c.target);
				constraintTargets.push(o);
				var m: Mat4 = null;
				if (o != null) {
					m = Mat4.identity().setFrom(o.transform.world);
					m.getInverse(m);
				}
				constraintTargetsI.push(m);
			}
			constraintMats = new Map();
		}
	}

	function updateConstraints() {
		if (data == null) return;
		var cs = data.raw.skin.constraints;
		if (cs == null) return;
		if (relativeBoneConstraints) {
			getConstraintsFromParentRelative(cs);
		}
		else {
			getConstraintsFromScene(cs);
		}
		// Update matrices
		for (i in 0...cs.length) {
			var c = cs[i];
			var bone = getBone(c.bone);
			if (bone == null) continue;
			var o = constraintTargets[i];
			if (o == null) continue;
			if (c.type == "CHILD_OF") {
				var m = constraintMats.get(bone);
				if (m == null) {
					m = Mat4.identity();
					constraintMats.set(bone, m);
				}
				m.setFrom(object.parent.transform.world); // Armature transform
				m.multmat(constraintTargetsI[i]); // Roll back initial hitbox transform
				m.multmat(o.transform.world); // Current hitbox transform
				m1.getInverse(object.parent.transform.world); // Roll back armature transform
				m.multmat(m1);
			}
		}
	}

	var onUpdates: Array<Void->Void> = null;
	public function notifyOnUpdate(f: Void->Void) {
		if (onUpdates == null) onUpdates = [];
		onUpdates.push(f);
	}

	// Do animation here
	public function animationLoop(f: Array<Mat4>->Void){
		updateAnimation = f;
	}

	override public function updateActionTrack(sampler: ActionSampler) {
		if(sampler.paused) return;
		var bones = data.geom.actions.get(sampler.action);
		for(b in bones){
			if (b.anim != null) {
				updateTrack(b.anim, sampler);
				break;
			}
		}
	}

	public function sampleAction(sampler: ActionSampler, anctionMats: Array<Mat4>){
		var bones = data.geom.actions.get(sampler.action);
		for (i in 0...bones.length) {
			if (i == rootMotionIndex){
				updateAnimSampledRootMotion(bones[i].anim, anctionMats[i], sampler);
			}
			else {
				updateAnimSampled(bones[i].anim, anctionMats[i], sampler);
			}
		}

	}

	function updateAnimSampled(anim: TAnimation, m: Mat4, sampler: ActionSampler) {

		var track = anim.tracks[0];
		var sign = sampler.speed > 0 ? 1 : -1;

		var t = sampler.time;
		//t = t < 0 ? 0.1 : t;

		var ti = sampler.offset;
		//ti = ti < 0 ? 1 : ti;

		var t1 = track.frames[ti] * frameTime;
		var t2 = track.frames[ti + sign] * frameTime;
		var s: FastFloat = (t - t1) / (t2 - t1); // Linear

		m1.setF32(track.values, ti * 16); // Offset to 4x4 matrix array
		m2.setF32(track.values, (ti + sign) * 16);

		// Decompose
		m1.decompose(vpos, q1, vscl);
		m2.decompose(vpos2, q2, vscl2);

		// Lerp
		v1.lerp(vpos, vpos2, s);
		v2.lerp(vscl, vscl2, s);
		q3.lerp(q1, q2, s);

		// Compose
		m.fromQuat(q3);
		m.scale(v2);
		m._30 = v1.x;
		m._31 = v1.y;
		m._32 = v1.z;
	}

	function updateAnimSampledRootMotion(anim: TAnimation, m: Mat4, sampler: ActionSampler) {

		var track = anim.tracks[0];
		var sign = sampler.speed > 0 ? 1 : -1;

		var t = sampler.time;
		var tOld = sampler.timeOld;
		//t = t < 0 ? 0.1 : t;

		var ti = sampler.offset;
		var tiOld = sampler.offsetOld;
		//ti = ti < 0 ? 1 : ti;

		
		if(tiOld > track.frames.length - 2){
			ti = track.frames.length - 2;
			t = track.frames[ti + sign] * frameTime;
			tiOld = ti;
		}

		var t1 = track.frames[ti] * frameTime;
		var t2 = track.frames[ti + sign] * frameTime;
		var s: FastFloat = (t - t1) / (t2 - t1); // Linear

		m1.setF32(track.values, ti * 16); // Offset to 4x4 matrix array
		m2.setF32(track.values, (ti + sign) * 16);

		// Decompose
		m1.decompose(vpos, q1, vscl);
		m2.decompose(vpos2, q2, vscl2);

		// Lerp
		v1.lerp(vpos, vpos2, s);
		v2.lerp(vscl, vscl2, s);
		q3.lerp(q1, q2, s);

		// Compose
		m.fromQuat(q3);
		m.scale(v2);
		m._30 = v1.x;
		m._31 = v1.y;
		m._32 = v1.z;

		// Calculate delata for root motion
		t1 = track.frames[tiOld] * frameTime;
		t2 = track.frames[tiOld + sign] * frameTime;
		s = (tOld - t1) / (t2 - t1); // Linear

		m1.setF32(track.values, tiOld * 16); // Offset to 4x4 matrix array
		m2.setF32(track.values, (tiOld + sign) * 16);

		// Decompose
		m1.decompose(vpos, q1, vscl);
		m2.decompose(vpos2, q2, vscl2);

		// Lerp
		v1.lerp(vpos, vpos2, s);

		m._30 -= v1.x;
		m._31 -= v1.y;
		m._32 -= v1.z;
		
	}

	public function blendAction(actionMats1: Array<Mat4>, actionMats2: Array<Mat4>, resultMat: Array<Mat4>, factor: FastFloat = 0.0, layerMask: Int = -1, threshold: FastFloat = 0.1){

		if(factor < threshold) {
			for(i in 0...actionMats1.length){
				resultMat[i].setFrom(actionMats1[i]);
			}
		}
		else if(factor > 1.0 - threshold){
			for(i in 0...actionMats2.length){
				if(skeletonBones[i].bone_layers[layerMask] || layerMask < 0){
					resultMat[i].setFrom(actionMats2[i]);
				}
				else {
					resultMat[i].setFrom(actionMats1[i]);
				}
			}
		}
		else {
			for(i in 0...actionMats1.length){

				if(skeletonBones[i].bone_layers[layerMask] || layerMask < 0) {
					// Decompose
					m.setFrom(actionMats1[i]);
					m1.setFrom(actionMats2[i]);
					m.decompose(vpos, q1, vscl);
					m1.decompose(vpos2, q2, vscl2);
					// Lerp
					v1.lerp(vpos, vpos2, factor);
					v2.lerp(vscl, vscl2, factor);
					q3.lerp(q1, q2, factor);
					// Compose
					m2.fromQuat(q3);
					m2.scale(v2);
					m2._30 = v1.x;
					m2._31 = v1.y;
					m2._32 = v1.z;
					if(i == rootMotionIndex){
						m2._30 = rootMotionLockX ? vpos2.x : m2._30;
						m2._31 = rootMotionLockY ? vpos2.y : m2._31;
						m2._32 = rootMotionLockZ ? vpos2.z : m2._32;
					}
					// Return Result
					resultMat[i].setFrom(m2);
				}
				else {
					resultMat[i].setFrom(actionMats1[i]);
				}
			}
		}
	}

	public function additiveBlendAction(baseActionMats: Array<Mat4>, addActionMats: Array<Mat4>, restPoseMats: Array<Mat4>, resultMat: Array<Mat4>, factor: FastFloat, layerMask: Int = -1, threshold: FastFloat = 0.1){

		if(factor < threshold) {
			for(i in 0...baseActionMats.length){
				resultMat[i].setFrom(baseActionMats[i]);
			}
		}
		else{
			for(i in 0...baseActionMats.length){

				if(skeletonBones[i].bone_layers[layerMask] || layerMask < 0) {
					// Decompose
					m.setFrom(baseActionMats[i]);
					m1.setFrom(addActionMats[i]);
					bm.setFrom(restPoseMats[i]);

					m.decompose(vpos, q1, vscl);
					m1.decompose(vpos2, q2, vscl2);
					bm.decompose(vpos3, q3, vscl3);

					// Add Transforms
					v1.setFrom(vpos);
					v2.setFrom(vpos2);
					v2.sub(vpos3);
					v2.mult(factor);
					v1.add(v2);

					// Add Scales
					vscl2.mult(factor);
					v2.set(1-factor, 1-factor, 1-factor, 1);
					v2.add(vscl2);
					v2.x *= vscl.x;
					v2.y *= vscl.y;
					v2.z *= vscl.z;
					v2.w = 1.0;

					// Add rotations
					q2.lerp(q3, q2, factor);
					wm.fromQuat(q3);
					wm.getInverse(wm);
					q3.fromMat(wm).normalize();
					q3.multquats(q3, q2);
					q3.multquats(q1, q3);

					// Compose
					m2.fromQuat(q3);
					m2.scale(v2);
					m2._30 = v1.x;
					m2._31 = v1.y;
					m2._32 = v1.z;
					// Return Result
					resultMat[i].setFrom(m2);
				}
				else{
					resultMat[i].setFrom(baseActionMats[i]);
				}
			}
		}
	}

	public function removeUpdate(f: Void->Void) {
		onUpdates.remove(f);
	}

	function updateBonesOnly() {
		if (boneChildren != null) {
			for (i in 0...skeletonBones.length) {
				var b = skeletonBones[i]; // TODO: blendTime > 0
				m.setFrom(matsFast[i]);
				updateBoneChildren(b, m);
			}
		}
	}

	function updateSkinGpu() {
		var bones = skeletonBones;

		// Update skin buffer
		for (i in 0...bones.length) {
			if (constraintMats != null) {
				var m = constraintMats.get(bones[i]);
				if (m != null) {
					updateSkinBuffer(m, i);
					continue;
				}
			}

			m.setFrom(matsFast[i]);

			if (absMats != null && i < absMats.length) absMats[i].setFrom(m);
			if (boneChildren != null) updateBoneChildren(bones[i], m);

			m.multmats(m, data.geom.skeletonTransformsI[i]);
			updateSkinBuffer(m, i);
		}
	}

	function updateSkinBuffer(m: Mat4, i: Int) {
		// Dual quat skinning
		m.decompose(vpos, q1, vscl);
		q1.normalize();
		q2.set(vpos.x, vpos.y, vpos.z, 0.0);
		q2.multquats(q2, q1);
		skinBuffer[i * 12] = q1.x; // Real
		skinBuffer[i * 12 + 1] = q1.y;
		skinBuffer[i * 12 + 2] = q1.z;
		skinBuffer[i * 12 + 3] = q1.w;
		skinBuffer[i * 12 + 4] = q2.x * 0.5; // Dual
		skinBuffer[i * 12 + 5] = q2.y * 0.5;
		skinBuffer[i * 12 + 6] = q2.z * 0.5;
		skinBuffer[i * 12 + 7] = q2.w * 0.5;
		skinBuffer[i * 12 + 8] = vscl.x;
		skinBuffer[i * 12 + 9] = vscl.y;
		skinBuffer[i * 12 + 10] = vscl.z;
		skinBuffer[i * 12 + 11] = 1.0;

	}

	public override function getTotalFrames(sampler: ActionSampler): Int {
		var bones = data.geom.actions.get(sampler.action);
		var track = bones[0].anim.tracks[0];
		return Std.int(track.frames[track.frames.length - 1] - track.frames[0]);
	}

	public function getBone(name: String): TObj {
		if (skeletonBones == null) return null;
		for (b in skeletonBones) if (b.name == name) return b;
		return null;
	}

	function getBoneIndex(bone: TObj, bones: Array<TObj> = null): Int {
		if (bones == null) bones = skeletonBones;
		if (bones != null) for (i in 0...bones.length) if (bones[i] == bone) return i;
		return -1;
	}

	public function getBoneMat(bone: TObj, actionMats: Array<Mat4> = null): Mat4 {
		if(actionMats == null) actionMats = skeletonMats;
		return actionMats != null ? actionMats[getBoneIndex(bone)] : null;
	}

	public function getWorldMat(bone: TObj, actionMats: Array<Mat4> = null): Mat4 {

		if (actionMats == null) actionMats = skeletonMats;
		if (applyParent == null) {
			applyParent = [];
			for (m in actionMats) applyParent.push(true);
		}
		var i = getBoneIndex(bone);
		wm.setFrom(actionMats[i]);
		multParents(wm, i, skeletonBones, actionMats);
		return wm;
	}

	public function getBoneLen(bone: TObj): FastFloat {
		var refs = data.geom.skeletonBoneRefs;
		var lens = data.geom.skeletonBoneLens;
		for (i in 0...refs.length) if (refs[i] == bone.name) return lens[i];
		return 0.0;
	}

	// Returns bone length with scale applied
	public function getBoneAbsLen(bone: TObj): FastFloat {
		var refs = data.geom.skeletonBoneRefs;
		var lens = data.geom.skeletonBoneLens;
		var scale = object.parent.transform.world.getScale().z;
		for (i in 0...refs.length) if (refs[i] == bone.name) return lens[i] * scale;
		return 0.0;
	}

	// Returns bone matrix in world space
	public function getAbsWorldMat(bone: TObj, actionMats: Array<Mat4> = null): Mat4 {
		if(actionMats == null) actionMats = skeletonMats;
		var wm = getWorldMat(bone, actionMats);
		wm.multmat(object.parent.transform.world);
		return wm;
	}

	public function solveIK(effector: TObj, goal: Vec4, precision = 0.01, maxIterations = 100, chainLenght = 100, pole: Vec4 = null, rollAngle = 0.0, actionMats: Array<Mat4> = null ) {
		if(actionMats == null) actionMats = skeletonMats;
		
		// Array of bones to solve IK for, effector at 0
		var bones: Array<TObj> = [];

		// Array of bones lengths, effector length at 0
		var lengths: Array<FastFloat> = [];

		// Array of bones matrices in world coordinates, effector at 0
		var boneWorldMats: Array<Mat4>;

		var tempLoc = new Vec4();
		var tempRot = new Quat();
		var tempRot2 = new Quat();
		var tempScl = new Vec4();
		var roll = new Quat().fromEuler(0, rollAngle, 0);

		// Store all bones and lengths in array
		var tip = effector;
		bones.push(tip);
		var root = tip;

		while (root.parent != null) {
			if (bones.length > chainLenght - 1) break;
			bones.push(root.parent);
			root = root.parent;
		}

		// Get all bone mats in world space
		boneWorldMats = getWorldMatsFast(effector, bones.length, actionMats);

		var tempIndex = 0;
		for(b in bones){
			lengths.push(getBoneLen(b) * boneWorldMats[boneWorldMats.length - 1 - tempIndex].getScale().x);
			tempIndex++;
		}

		// Root bone
		root = bones[bones.length - 1];

		// World matrix of root bone
		var rootWorldMat = getAbsWorldMat(root, actionMats).clone();
		// Distance from root to goal
		var dist = Vec4.distance(goal, rootWorldMat.getLoc());


		// Total bones length
		var totalLength: FastFloat = 0.0;
		for (l in lengths) totalLength += l;

		// Unreachable distance
		if (dist > totalLength) {
			// Calculate unit vector from root to goal
			var newLook = goal.clone();
			newLook.sub(rootWorldMat.getLoc());
			newLook.normalize();

			// Rotate root bone to point at goal
			rootWorldMat.decompose(tempLoc, tempRot, tempScl);
			tempRot2.fromTo(rootWorldMat.look().normalize(), newLook);
			tempRot2.mult(tempRot);
			tempRot2.mult(roll);
			rootWorldMat.compose(tempLoc, tempRot2, tempScl);

			// Set bone matrix in local space from world space
			setBoneMatFromWorldMat(rootWorldMat, root, actionMats);

			// Set child bone rotations to zero
			for (i in 0...bones.length - 1) {
				getBoneMat(bones[i], actionMats).decompose(tempLoc, tempRot, tempScl);
				getBoneMat(bones[i], actionMats).compose(tempLoc, roll, tempScl);
			}
			return;
		}

		// Array of bone locations in world space, root location at [0]
		var boneWorldLocs: Array<Vec4> = [];
		for (b in boneWorldMats) boneWorldLocs.push(b.getLoc());

		// Solve FABRIK
		var vec = new Vec4();
		var startLoc = boneWorldLocs[0].clone();
		var l = boneWorldLocs.length;
		var testLength = 0;

		for (iter in 0...maxIterations) {
			// Backward
			vec.setFrom(goal);
			vec.sub(boneWorldLocs[l - 1]);
			vec.normalize();
			vec.mult(lengths[0]);
			boneWorldLocs[l - 1].setFrom(goal);
			boneWorldLocs[l - 1].sub(vec);

			for (j in 1...l) {
				vec.setFrom(boneWorldLocs[l - 1 - j]);
				vec.sub(boneWorldLocs[l - j]);
				vec.normalize();
				vec.mult(lengths[j]);
				boneWorldLocs[l - 1 - j].setFrom(boneWorldLocs[l - j]);
				boneWorldLocs[l - 1 - j].add(vec);
			}

			// Forward
			boneWorldLocs[0].setFrom(startLoc);
			for (j in 1...l) {
				vec.setFrom(boneWorldLocs[j]);
				vec.sub(boneWorldLocs[j - 1]);
				vec.normalize();
				vec.mult(lengths[l - j]);
				boneWorldLocs[j].setFrom(boneWorldLocs[j - 1]);
				boneWorldLocs[j].add(vec);
			}

			if (Vec4.distance(boneWorldLocs[l - 1], goal) - lengths[0] <= precision) break;
		}

		// Pole rotation implementation
		if (pole != null) {
			for (i in 1...boneWorldLocs.length - 1) {
				boneWorldLocs[i] = moveTowardPole(boneWorldLocs[i - 1].clone(), boneWorldLocs[i].clone(), boneWorldLocs[i + 1].clone(), pole.clone());
			}
		}

		// Correct rotations
		// Applying locations and rotations
		var tempLook = new Vec4();
		var tempLoc2 = new Vec4();

		for (i in 0...l - 1){
			// Decompose matrix
			boneWorldMats[i].decompose(tempLoc, tempRot, tempScl);

			// Rotate to point to parent bone
			tempLoc2.setFrom(boneWorldLocs[i + 1]);
			tempLoc2.sub(boneWorldLocs[i]);
			tempLoc2.normalize();
			tempLook.setFrom(boneWorldMats[i].look());
			tempLook.normalize();
			tempRot2.fromTo(tempLook, tempLoc2);
			tempRot2.mult(tempRot);
			tempRot2.mult(roll);

			// Compose matrix with new rotation and location
			boneWorldMats[i].compose(boneWorldLocs[i], tempRot2, tempScl);

			// Set bone matrix in local space from world space
			setBoneMatFromWorldMat(boneWorldMats[i], bones[bones.length - 1 - i], actionMats);
		}

		// Decompose matrix
		boneWorldMats[l - 1].decompose(tempLoc, tempRot, tempScl);

		// Rotate to point to goal
		tempLoc2.setFrom(goal);
		tempLoc2.sub(tempLoc);
		tempLoc2.normalize();
		tempLook.setFrom(boneWorldMats[l - 1].look());
		tempLook.normalize();
		tempRot2.fromTo(tempLook, tempLoc2);
		tempRot2.mult(tempRot);
		tempRot2.mult(roll);

		// Compose matrix with new rotation and location
		boneWorldMats[l - 1].compose(boneWorldLocs[l - 1], tempRot2, tempScl);

		// Set bone matrix in local space from world space
		setBoneMatFromWorldMat(boneWorldMats[l - 1], bones[0], actionMats);
	}

	public function moveTowardPole(bone0Pos: Vec4, bone1Pos: Vec4, bone2Pos: Vec4, polePos: Vec4): Vec4 {
		// Setup projection plane at current bone's parent
		var plane = new Plane();

		// Plane normal from parent of current bone to child of current bone
		var planeNormal = new Vec4().setFrom(bone2Pos);
		planeNormal.sub(bone0Pos);
		planeNormal.normalize();
		plane.set(planeNormal, bone0Pos);

		// Create and project ray from current bone to plane
		var rayPos = new Vec4();
		rayPos.setFrom(bone1Pos);
		var rayDir = new Vec4();
		rayDir.sub(planeNormal);
		rayDir.normalize();
		var rayBone = new Ray(rayPos, rayDir);

		// Projection point of current bone on plane
		// If pole does not project on the plane
		if (!rayBone.intersectsPlane(plane)) {
			rayBone.direction = planeNormal;
		}

		var bone1Proj = rayBone.intersectPlane(plane);

		// Create and project ray from pole to plane
		rayPos.setFrom(polePos);
		var rayPole = new Ray(rayPos, rayDir);

		// If pole does not project on the plane
		if (!rayPole.intersectsPlane(plane)) {
			rayPole.direction = planeNormal;
		}

		// Projection point of pole on plane
		var poleProj = rayPole.intersectPlane(plane);

		// Caclulate unit vectors from pole projection to parent bone
		var poleProjNormal = new Vec4();
		poleProjNormal.setFrom(bone0Pos);
		poleProjNormal.sub(poleProj);
		poleProjNormal.normalize();

		// Calculate unit vector from current bone projection to parent bone
		var bone1ProjNormal = new Vec4();
		bone1ProjNormal.setFrom(bone0Pos);
		bone1ProjNormal.sub(bone1Proj);
		bone1ProjNormal.normalize();

		// Calculate rotation quaternion
		var rotQuat = new Quat();
		rotQuat.fromTo(bone1ProjNormal, poleProjNormal);

		// Apply quaternion to current bone location
		var bone1Res = new Vec4().setFrom(bone1Pos);
		bone1Res.sub(bone0Pos);
		bone1Res.applyQuat(rotQuat);
		bone1Res.add(bone0Pos);

		// Return new location of current bone
		return bone1Res;
	}

	public function solveTwoBoneIK(effector: TObj, goal: Vec4, pole: Vec4 = null, rollAngle = 0.0, actionMats : Array<Mat4> = null) {
		if(actionMats == null) actionMats = skeletonMats;
		
		var roll = new Quat().fromEuler(0, rollAngle, 0);
		var root = effector.parent;

		// Get bone transforms in world space
		var effectorMat = getAbsWorldMat(effector, actionMats).clone();
		var rootMat = getAbsWorldMat(root, actionMats).clone();

		// Get bone lenghts
		var effectorLen = getBoneLen(effector) * effectorMat.getScale().x;
		var rootLen = getBoneLen(root) * rootMat.getScale().x;

		// Get distance form root to goal
		var goalLen = Math.abs(Vec4.distance(rootMat.getLoc(), goal));

		var totalLength = effectorLen + rootLen;

		// Get tip location of effector bone
		var effectorTipPos = new Vec4().setFrom(effectorMat.look()).normalize();
		effectorTipPos.mult(effectorLen);
		effectorTipPos.add(effectorMat.getLoc());

		// Get unit vector from root to effector tip
		var vectorRootEffector = new Vec4().setFrom(effectorTipPos).sub(rootMat.getLoc());
		vectorRootEffector.normalize();

		// Get unit vector from root to goal
		var vectorGoal = new Vec4().setFrom(goal).sub(rootMat.getLoc());
		vectorGoal.normalize();

		// Get unit vector of root bone
		var vectorRoot = new Vec4().setFrom(rootMat.look()).normalize();

		// Get unit vector of effector bone
		var vectorEffector = new Vec4().setFrom(effectorMat.look()).normalize();		
		
		// Get dot product of vectors
		var dot = new Vec4().setFrom(vectorRootEffector).dot(vectorRoot);
		// Calmp between -1 and 1
		dot = dot < -1.0 ? -1.0 : dot > 1.0 ? 1.0 : dot;
		// Gat angle A1
		var angleA1 = Math.acos(dot);

		// Get angle A2
		dot = new Vec4().setFrom(vectorRoot).mult(-1.0).dot(vectorEffector);
		dot = dot < -1.0 ? -1.0 : dot > 1.0 ? 1.0 : dot;
		var angleA2 = Math.acos(dot);

		// Get angle A3
		dot = new Vec4().setFrom(vectorRootEffector).dot(vectorGoal);
		dot = dot < -1.0 ? -1.0 : dot > 1.0 ? 1.0 : dot;
		var angleA3 = Math.acos(dot);

		// Get angle B1
		dot = (effectorLen * effectorLen - rootLen * rootLen - goalLen * goalLen) / (-2 * rootLen * goalLen);
		dot = dot < -1.0 ? -1.0 : dot > 1.0 ? 1.0 : dot;
		var angleB1 = Math.acos(dot);

		// Get angle B2
		dot = (goalLen * goalLen - rootLen * rootLen - effectorLen * effectorLen) / (-2 * rootLen * effectorLen);
		dot = dot < -1.0 ? -1.0 : dot > 1.0 ? 1.0 : dot;
		var angleB2 = Math.acos(dot);

		// Calculate rotation axes
		var axis0 = new Vec4().setFrom(vectorRootEffector).cross(vectorRoot).normalize();
		var axis1 = new Vec4().setFrom(vectorRootEffector).cross(vectorGoal).normalize();

		// Apply rotations to effector bone
		vpos.setFrom(effectorMat.getLoc());
		effectorMat.setLoc(new Vec4());
		effectorMat.applyQuat(new Quat().fromAxisAngle(axis0, angleB2 - angleA2));
		effectorMat.setLoc(vpos);
		setBoneMatFromWorldMat(effectorMat, effector, actionMats);

		// Apply rotations to root bone
		vpos.setFrom(rootMat.getLoc());
		rootMat.setLoc(new Vec4());
		rootMat.applyQuat(new Quat().fromAxisAngle(axis0, angleB1 - angleA1));
		rootMat.applyQuat(new Quat().fromAxisAngle(axis1, angleA3));
		rootMat.setLoc(vpos);
		setBoneMatFromWorldMat(rootMat, root, actionMats);

		// Recalculate new effector matrix
		effectorMat.setFrom(getAbsWorldMat(effector, actionMats));

		// Check if pole present
		if((pole != null) && (goalLen < totalLength)) {
		
			// Calculate new effector tip position
			vscl.setFrom(effectorMat.look()).normalize();
			vscl.mult(effectorLen);
			vscl.add(effectorMat.getLoc());

			// Calculate new effector position from pole
			vpos2 = moveTowardPole(rootMat.getLoc(), effectorMat.getLoc(), vscl, pole);

			// Orient root bone to new effector position
			vpos.setFrom(rootMat.getLoc());
			rootMat.setLoc(new Vec4());
			vpos3.setFrom(vpos2).sub(vpos).normalize();
			rootMat.applyQuat(new Quat().fromTo(rootMat.look().normalize(), vpos3));
			rootMat.setLoc(vpos);
			
			// Orient effector bone to new position
			vpos.setFrom(effectorMat.getLoc());
			effectorMat.setLoc(new Vec4());
			vpos3.setFrom(vscl).sub(vpos2).normalize();
			effectorMat.applyQuat(new Quat().fromTo(effectorMat.look().normalize(), vpos3));
			effectorMat.setLoc(vpos2);
		}

		// Apply roll to root bone
		vpos.setFrom(rootMat.getLoc());
		rootMat.setLoc(new Vec4());
		rootMat.applyQuat(new Quat().fromAxisAngle(rootMat.look().normalize(), rollAngle));
		rootMat.setLoc(vpos);

		// Apply roll to effector bone
		vpos.setFrom(effectorMat.getLoc());
		effectorMat.setLoc(new Vec4());
		effectorMat.applyQuat(new Quat().fromAxisAngle(effectorMat.look().normalize(), rollAngle));
		effectorMat.setLoc(vpos);

		// Finally set root and effector matrices in local space
		setBoneMatFromWorldMat(rootMat, root, actionMats);
		setBoneMatFromWorldMat(effectorMat, effector, actionMats);

	}

	// Returns an array of bone matrices in world space
	public function getWorldMatsFast(tip: TObj, chainLength: Int, actionMats: Array<Mat4> = null): Array<Mat4> {
		if(actionMats == null) actionMats = skeletonMats;
		var wmArray: Array<Mat4> = [];
		var armatureMat = object.parent.transform.world;
		var root = tip;
		var numP = chainLength;
		for (i in 0...chainLength) {
			var wm = getAbsWorldMat(root, actionMats);
			wmArray[chainLength - 1 - i] = wm.clone();
			root = root.parent;
			numP--;
		}

		// Root bone at [0]
		return wmArray;
	}

	// Set bone transforms in world space
	public function setBoneMatFromWorldMat(wm: Mat4, bone: TObj, actionMats: Array<Mat4> = null) {
		if(actionMats == null) actionMats = skeletonMats;
		var invMat = Mat4.identity();
		var tempMat = wm.clone();
		invMat.getInverse(object.parent.transform.world);
		tempMat.multmat(invMat);
		var bones: Array<TObj> = [];
		var pBone = bone;
		while (pBone.parent != null) {
			bones.push(pBone.parent);
			pBone = pBone.parent;
		}

		for (i in 0...bones.length) {
			var x = bones.length - 1;
			invMat.getInverse(getBoneMat(bones[x - i], actionMats));
			tempMat.multmat(invMat);
		}

		getBoneMat(bone, actionMats).setFrom(tempMat);
	}
}
#end