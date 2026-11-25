// Build an offline browser fixture from the same guest, bridge and manifest as the app.
// Usage: node tools/phone_linux_fixture.cjs <directory with library, wasm, kernel, bios, vga> <output.html>
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const assert = require("node:assert/strict");
const [directory, output] = process.argv.slice(2);
if (!output) throw Error("Expected an asset directory and an output HTML path");
const app = path.resolve(__dirname, "../App");
const readSwift = name => fs.readFileSync(path.join(app, name + ".swift"), "utf8");
const runtime = readSwift("PhoneLinuxRuntime");
function swiftString(name) {
    const match = new RegExp("static let " + name + ' = #"""\\r?\\n([\\s\\S]*?)\\r?\\n\\s*"""#').exec(runtime);
    assert.ok(match, name);
    return match[1];
}
const assets = {};
for (const [, name, size, digest] of readSwift("PhoneLinuxAssets").matchAll(/Asset\(name: "(.*?)", source: .*?, size: (\d+), hash: "([a-f0-9]+)"\)/g)) {
    const data = fs.readFileSync(path.join(directory, name));
    assert.equal(data.length, Number(size));
    assert.equal(crypto.createHash("sha256").update(data).digest("hex"), digest);
    assets[name] = data.toString(name === "library" ? "utf8" : "base64");
}
assert.equal(Object.keys(assets).length, 5);
const json = value => JSON.stringify(value).replace(/</g, "\\u003c");
const csp = readSwift("LocalCode").match(/<meta http-equiv="Content-Security-Policy"[^>]+>/)[0];
async function checks(run) {
    const started = Date.now();
    const input = "æble\npære\næble\n";
    const result = await run("sort | uniq -c; lua -e 'print(6*7)'; uname -s", input);
    if (!result.ok || !/2 æble/.test(result.text) || !result.text.includes("42\nLinux")) throw Error(JSON.stringify(result));
    const error = await run("echo fejl >&2; exit 17", "");
    if (error.ok || !error.error.includes("17") || !error.error.includes("fejl")) throw Error(JSON.stringify(error));
    const oversize = await run("head -c 81000 /dev/zero", "");
    if (oversize.ok || !oversize.error.includes("80 KB")) throw Error(JSON.stringify(oversize));
    const timeout = await run("while :; do :; done", "");
    if (timeout.error !== "timeout") throw Error("expected timeout " + JSON.stringify(timeout));
    const pending = run("while :; do :; done", "");
    setTimeout(() => window.cancelLinux(), 200);
    if ((await pending).error !== "cancelled") throw Error("expected cancellation");
    const recovered = await run("cat input.txt file-1.txt; cat files.json", "$(touch nope)\næøå",
        [{name:"Frugt $(test).txt", text:" pærer\n"}]);
    if (recovered.text !== '$(touch nope)\næøå pærer\n[{"path":"file-1.txt","name":"Frugt $(test).txt"}]') throw Error(JSON.stringify(recovered));
    return {passed:6, seconds:(Date.now()-started)/1000};
}
const script = "const assets=" + json(assets) + ";const guest=" + json(swiftString("worker")) + ";"
    + "async function run(code,input,sources=[]){" + swiftString("bridge") + "}\n"
    + "window.tests=(" + checks + ")(run);window.tests.then(v=>document.body.textContent=JSON.stringify(v),e=>document.body.textContent=e.message);";
fs.writeFileSync(output, "<!doctype html><meta charset=utf-8>" + csp + "<body>Testing…<script>" + script + "</script></body>");
