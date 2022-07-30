package iron.object;

import iron.math.Mat4;
import kha.graphics4.Graphics;
import iron.data.MaterialData;
import iron.data.ConstData;
import iron.object.Uniforms;
import iron.object.Transform;

class CollectionObject extends Object {

	public var instanceTransform: Mat4 = Mat4.identity();

	public function new() {
		super();
		
	}

	public override function remove() {
		super.remove();
	}
}
