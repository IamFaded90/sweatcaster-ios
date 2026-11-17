// Bundle with three@0.180.0, @pixiv/three-vrm@3.5.5 and esbuild@0.25.11.
// esbuild renderer.mjs --bundle --minify --format=iife --target=safari16 --legal-comments=none --outfile=renderer.js
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { VRMLoaderPlugin, VRMUtils } from '@pixiv/three-vrm';

const limit = 24_000_000;
const bridge = state => window.webkit?.messageHandlers?.vrm?.postMessage(state);

function connectAvatar() {
  const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'low-power' });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
  renderer.setClearColor(0x172129);
  document.body.appendChild(renderer.domElement);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(32, 1, 0.01, 100);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enablePan = false;
  controls.minPolarAngle = 0.24;
  controls.maxPolarAngle = Math.PI * 0.85;
  scene.add(new THREE.HemisphereLight(0xe8faff, 0x687e8d, 2.1));
  const key = new THREE.DirectionalLight(0xf4ffea, 2.3);
  key.position.set(2, 3, 3);
  scene.add(key);

  let incoming;
  let usedBytes = 0;
  let avatar;
  let raf = null;
  let lastFrame = 0;
  let animated = false;
  let portrait = false;
  let breathTime = 0;
  let mouthExpression;
  let blinkExpressions = [];

  function redraw() {
    if (raf !== null || !avatar || document.hidden) return;
    raf = requestAnimationFrame(now => {
      raf = null;
      const delta = lastFrame > 0 ? Math.min(0.05, (now - lastFrame) / 1000) : 0;
      lastFrame = now;
      if (portrait) {
        breathTime = animated ? breathTime + delta : 0;
        avatar.expressionManager?.setValue('breath', animated ? (1 - Math.cos(breathTime * 1.7)) / 2 : 0);
      }
      avatar.update(animated ? delta : 0);
      renderer.render(scene, camera);
      if (animated) redraw();
    });
  }

  function resize() {
    const width = Math.max(window.innerWidth, 1);
    const height = Math.max(window.innerHeight, 1);
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    redraw();
  }
  resize();
  window.addEventListener('resize', resize);
  document.addEventListener('visibilitychange', redraw);
  controls.addEventListener('change', redraw);
  renderer.domElement.addEventListener('webglcontextlost', event => {
    event.preventDefault();
    animated = false;
    bridge('error');
  });
  window.addEventListener('pagehide', () => {
    if (raf !== null) cancelAnimationFrame(raf);
    if (avatar) VRMUtils.deepDispose(avatar.scene);
    avatar = undefined;
    controls.dispose();
    renderer.dispose();
  });

  function frameAvatar() {
    const box = new THREE.Box3().setFromObject(avatar.scene, true);
    const size = box.getSize(new THREE.Vector3());
    const center = box.getCenter(new THREE.Vector3());
    if (!Number.isFinite(size.y) || size.y < 0.02 || size.y > 10) throw new Error('Avatar bounds');
    const distance = Math.max(size.y, size.x / camera.aspect) / (2 * Math.tan(camera.fov * Math.PI / 360));
    controls.target.copy(center);
    camera.position.set(center.x, center.y + size.y * (portrait ? 0 : 0.05), center.z + distance * (portrait ? 1.08 : 1.18));
    controls.minDistance = Math.max(size.y * (portrait ? 0.55 : 0.28), 0.05);
    controls.maxDistance = distance * 2.4;
    camera.near = Math.max(0.005, size.y * 0.012);
    camera.far = controls.maxDistance + size.y * 4;
    camera.updateProjectionMatrix();
    controls.update();
  }

  window.avatarBegin = length => {
    if (!Number.isInteger(length) || length < 28 || length > limit || avatar) throw new Error('Avatar size');
    incoming = new Uint8Array(length);
    usedBytes = 0;
  };

  window.avatarAppend = chunk => {
    if (!incoming || typeof chunk !== 'string' || chunk.length > 350_000) throw new Error('Avatar chunk');
    const part = atob(chunk);
    if (usedBytes + part.length > incoming.length) throw new Error('Avatar exceeds size');
    for (let offset = 0; offset < part.length; offset++) incoming[usedBytes + offset] = part.charCodeAt(offset);
    usedBytes += part.length;
  };

  window.avatarFinish = async (sample, portraitMode = false) => {
    if (!incoming || incoming.length !== usedBytes) throw new Error('Incomplete avatar');
    const bytes = incoming.buffer;
    incoming = undefined;
    const loading = new THREE.LoadingManager();
    loading.setURLModifier(url => {
      if (!url.startsWith('blob:')) throw new Error('Only embedded model resources are allowed');
      return url;
    });
    const loader = new GLTFLoader(loading);
    loader.register(parser => new VRMLoaderPlugin(parser));
    const asset = await loader.parseAsync(bytes, '');
    avatar = asset.userData.vrm;
    if (!avatar) throw new Error('Expected a VRM model');
    VRMUtils.rotateVRM0(avatar);
    portrait = portraitMode;
    if (portrait) {
      controls.minAzimuthAngle = -0.54;
      controls.maxAzimuthAngle = 0.54;
      controls.minPolarAngle = Math.PI / 2 - 0.18;
      controls.maxPolarAngle = Math.PI / 2 + 0.18;
    }
    if (sample) {
      const leftArm = avatar.humanoid.getNormalizedBoneNode('leftUpperArm');
      const rightArm = avatar.humanoid.getNormalizedBoneNode('rightUpperArm');
      if (leftArm && rightArm) {
        leftArm.rotation.z = -1.05;
        rightArm.rotation.z = 1.05;
      }
    }
    const expressions = avatar.expressionManager;
    mouthExpression = ['aa', 'oh', 'ou', 'ee', 'ih'].find(name => expressions?.getExpression(name));
    blinkExpressions = expressions?.getExpression('blink') ? ['blink']
      : ['blinkLeft', 'blinkRight'].filter(name => expressions?.getExpression(name));
    scene.add(avatar.scene);
    avatar.update(0);
    frameAvatar();
    renderer.render(scene, camera);
    return true;
  };

  window.avatarMotion = (active, mouth, blink) => {
    if (!avatar) return;
    animated = active === 1;
    if (!animated) lastFrame = 0;
    const opening = animated && Number.isFinite(mouth) ? THREE.MathUtils.clamp(mouth, 0, 1) : 0;
    if (portrait) {
      avatar.expressionManager?.setValue('ih', opening >= 0.16 && opening < 0.57 ? 1 : 0);
      avatar.expressionManager?.setValue('aa', opening >= 0.57 ? 1 : 0);
    } else if (mouthExpression) {
      avatar.expressionManager.setValue(mouthExpression, opening);
    }
    for (const expression of blinkExpressions) avatar.expressionManager.setValue(expression, animated && blink === 1 ? 1 : 0);
    redraw();
  };

  bridge('ready');
}

try { connectAvatar(); }
catch { bridge('error'); }
