/* Renderer for the village's unmasked, normal-blend portrait models. */
(async function () {
    const notify = state => window.webkit?.messageHandlers.cubism?.postMessage(state);
    try {
        const { mocData, images } = window.portraitModel;
        const bytes = Uint8Array.from(atob(mocData), value => value.charCodeAt(0));
        let moc;
        const coreDeadline = Date.now() + 12000;
        while (!moc && Date.now() < coreDeadline) {
            try { moc = Live2DCubismCore.Moc.fromArrayBuffer(bytes.buffer); } catch (_) {}
            if (!moc) await new Promise(resolve => setTimeout(resolve, 25));
        }
        if (!moc) throw new Error("Cubism kunne ikke læse modellen");
        const model = Live2DCubismCore.Model.fromMoc(moc);
        if (!model || model.drawables.maskCounts.some(count => count !== 0) || model.offscreens?.count) {
            throw new Error("Modellen bruger et lag, denne afspiller ikke understøtter");
        }
        const canvas = document.querySelector("canvas");
        const gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true });
        if (!gl) throw new Error("WebGL kunne ikke startes");
        const program = gl.createProgram();
        function attach(type, source) {
            const shader = gl.createShader(type);
            gl.shaderSource(shader, source);
            gl.compileShader(shader);
            if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
            gl.attachShader(program, shader);
        }
        attach(gl.VERTEX_SHADER, `
            attribute vec2 point, uv;
            uniform vec2 scale, offset;
            varying mediump vec2 texturePoint;
            void main() {
                gl_Position = vec4(point * scale + offset, 0.0, 1.0);
                texturePoint = vec2(uv.x, 1.0 - uv.y);
            }
        `);
        attach(gl.FRAGMENT_SHADER, `
            precision mediump float;
            uniform sampler2D image;
            uniform float opacity;
            varying mediump vec2 texturePoint;
            void main() {
                vec4 color = texture2D(image, texturePoint);
                gl_FragColor = vec4(color.rgb, color.a) * opacity;
            }
        `);
        gl.linkProgram(program);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
        gl.useProgram(program);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
        const textures = await Promise.all(images.map(source => new Promise((resolve, reject) => {
            const image = new Image();
            image.onerror = reject;
            image.onload = () => {
                const texture = gl.createTexture();
                gl.bindTexture(gl.TEXTURE_2D, texture);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
                gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
                gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
                resolve(texture);
            };
            image.src = source;
        })));
        const drawables = model.drawables;
        const pointBuffer = gl.createBuffer(), uvBuffer = gl.createBuffer(), indexBuffer = gl.createBuffer();
        const point = gl.getAttribLocation(program, "point"), uv = gl.getAttribLocation(program, "uv");
        const scale = gl.getUniformLocation(program, "scale"), offset = gl.getUniformLocation(program, "offset");
        const opacity = gl.getUniformLocation(program, "opacity");
        const order = Array.from({ length: drawables.count }, (_, index) => index);
        const eye = model.parameters.ids.indexOf("ParamEyeLOpen");
        const mouth = model.parameters.ids.indexOf("ParamMouthOpenY");
        const breathParameter = model.parameters.ids.indexOf("ParamBreath");
        if (eye < 0 || mouth < 0 || breathParameter < 0) throw new Error("Modellen mangler øjen- eller mundstyring");
        function attribute(buffer, location, values) {
            gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
            gl.bufferData(gl.ARRAY_BUFFER, values, gl.DYNAMIC_DRAW);
            gl.enableVertexAttribArray(location);
            gl.vertexAttribPointer(location, 2, gl.FLOAT, false, 0, 0);
        }
        let lastFrame = [1, 0, 0];
        window.renderPortrait = (eyeOpen, mouthOpen, breath = 0) => {
            lastFrame = [eyeOpen, mouthOpen, breath];
            model.parameters.values[eye] = eyeOpen;
            model.parameters.values[mouth] = mouthOpen;
            model.parameters.values[breathParameter] = Math.min(1, Math.max(0, breath));
            model.update();
            const pixels = Math.min(window.devicePixelRatio || 1, 2);
            const width = Math.max(1, Math.round(canvas.clientWidth * pixels));
            const height = Math.max(1, Math.round(canvas.clientHeight * pixels));
            if (canvas.width !== width) canvas.width = width;
            if (canvas.height !== height) canvas.height = height;
            gl.viewport(0, 0, width, height);
            gl.clear(gl.COLOR_BUFFER_BIT);
            const info = model.canvasinfo;
            const fit = Math.max(width / info.CanvasWidth, height / info.CanvasHeight);
            gl.uniform2f(scale, 2 * info.PixelsPerUnit * fit / width, 2 * info.PixelsPerUnit * fit / height);
            gl.uniform2f(offset, (2 * info.CanvasOriginX - info.CanvasWidth) * fit / width,
                (info.CanvasHeight - 2 * info.CanvasOriginY) * fit / height);
            const orders = model.getRenderOrders();
            order.sort((a, b) => orders[a] - orders[b]);
            for (const i of order) {
                if (!drawables.opacities[i] || !(drawables.dynamicFlags[i] & 1)) continue;
                attribute(pointBuffer, point, drawables.vertexPositions[i]);
                attribute(uvBuffer, uv, drawables.vertexUvs[i]);
                gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
                gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, drawables.indices[i], gl.DYNAMIC_DRAW);
                gl.bindTexture(gl.TEXTURE_2D, textures[drawables.textureIndices[i]]);
                gl.uniform1f(opacity, drawables.opacities[i]);
                gl.drawElements(gl.TRIANGLES, drawables.indexCounts[i], gl.UNSIGNED_SHORT, 0);
            }
        };
        window.renderPortrait(1, 0);
        new ResizeObserver(() => window.renderPortrait(...lastFrame)).observe(canvas);
        canvas.addEventListener("webglcontextlost", () => notify("failed"));
        notify("ready");
    } catch (error) {
        window.portraitStartupError = String(error);
        console.error(error);
        notify("failed");
    }
})();

