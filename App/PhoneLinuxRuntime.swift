import Foundation
import WebKit

enum PhoneLinux {
    // Executed inside a dedicated Worker. Terminating that Worker also stops the guest CPU.
    static let worker = #"""
    self.onmessage = async ({data: {files, code, input, sources}}) => {
      const fail = message => postMessage({ok:false, error:String(message).slice(0,300)});
      try {
        const bytes = name => Uint8Array.from(atob(files[name]), c => c.charCodeAt(0)).buffer;
        const machine = new V86({
          bios: {buffer:bytes('bios')}, vga_bios: {buffer:bytes('vga')}, bzimage: {buffer:bytes('kernel')},
          wasm_fn: async imports => (await WebAssembly.instantiate(bytes('wasm'), imports)).instance.exports,
          filesystem:{}, memory_size:64 * 1024 * 1024, autostart:false,
          cmdline:'tsc=reliable mitigations=off random.trust_cpu=on',
          disable_keyboard:true, disable_mouse:true, disable_speaker:true
        });
        const encoder = new TextEncoder();
        const decoder = new TextDecoder('utf-8', {fatal:true});
        let tail = '', phase = 'boot';
        machine.add_listener('emulator-ready', () => machine.run());
        machine.add_listener('serial0-output-byte', async byte => {
          tail = (tail + String.fromCharCode(byte)).slice(-120);
          try {
            if (phase === 'boot' && tail.endsWith('~% ')) {
              phase = 'run';
              postMessage({started:true});
              await machine.create_file('/task.sh', encoder.encode(code));
              await machine.create_file('/input.txt', encoder.encode(input));
              for (let i = 0; i < sources.length; i++) {
                await machine.create_file('/file-' + (i + 1) + '.txt', encoder.encode(sources[i].text));
              }
              const index = sources.map((source, i) => ({path:'file-' + (i + 1) + '.txt', name:source.name}));
              await machine.create_file('/files.json', encoder.encode(JSON.stringify(index)));
              // All user-controlled text is written as file contents, independent of the terminal command.
              machine.serial0_send("cd /mnt; (ulimit -f 192; /bin/sh task.sh <input.txt >/tmp/out 2>/tmp/err); rc=$?; head -c 80001 /tmp/out >out; head -c 1024 /tmp/err >err; echo $rc >status; echo FADED-DONE-$((6*7))\n");
            } else if (phase === 'run' && tail.endsWith('\nFADED-DONE-42\r\n')) {
              phase = 'done';
              const read = async name => decoder.decode(await machine.read_file('/' + name));
              const status = (await read('status')).trim();
              if (status !== '0') { fail('Linux afsluttede med kode ' + status + '. ' + (await read('err')).trim()); return; }
              const output = await machine.read_file('/out');
              if (output.byteLength > 80000) { fail('Resultatet er større end 80 KB.'); return; }
              postMessage({ok:true, text:output.length ? decoder.decode(output) : 'Kommandoen blev udført uden tekstoutput.'});
            }
          } catch (error) { fail(error.message || error); }
        });
      } catch (error) { fail(error.message || error); }
    };
    """#
    static let bridge = #"""
    return await new Promise(resolve => {
      if (window.cancelLinux) window.cancelLinux();
      let worker, address, timer, settled = false;
      const finish = value => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (worker) worker.terminate();
        if (address) URL.revokeObjectURL(address);
        window.cancelLinux = null;
        resolve(value);
      };
      window.cancelLinux = () => finish({ok:false,error:'cancelled'});
      const limit = ms => {
        clearTimeout(timer);
        timer = setTimeout(() => finish({ok:false,error:'timeout'}), ms);
      };
      try {
        address = URL.createObjectURL(new Blob([assets.library, '\n', guest], {type:'text/javascript'}));
        const {library, ...files} = assets;
        worker = new Worker(address);
        worker.onerror = event => { event.preventDefault(); finish({ok:false,error:event.message || 'Linux kunne ikke starte.'}); };
        worker.onmessage = event => event.data.started ? limit(25000) : finish(event.data);
        limit(90000);
        worker.postMessage({files,code,input,sources});
      } catch (error) { finish({ok:false,error:String(error.message || error)}); }
    });
    """#
}

extension LocalCodeRunner {
    func executeLinux(_ recipe: LocalCode.Recipe, input: String, files: [AgentWorkspace.CodeFile]) async throws -> String {
        guard ready, recipe.code.utf8.count <= 8_000, files.count <= 5,
              files.reduce(input.utf8.count, { $0 + $1.text.utf8.count }) <= 160_000 else { throw LocalCode.Failure.invalid }
        let assets = try await PhoneLinuxAssets.shared.payload()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let value = try await web.callAsyncJavaScript(PhoneLinux.bridge,
                arguments: ["assets": assets, "code": recipe.code, "input": input, "guest": PhoneLinux.worker,
                            "sources": files.map { ["name": $0.name, "text": $0.text] }], in: nil, contentWorld: .page)
            try Task.checkCancellation()
            guard let outcome = value as? [String: Any], let ok = outcome["ok"] as? Bool else { throw LocalCode.Failure.invalid }
            guard ok else {
                let message = outcome["error"] as? String ?? "Ukendt fejl"
                if message == "timeout" { throw LocalCode.Failure.timeout }
                if message == "cancelled" { throw LocalCode.Failure.stopped }
                throw LocalCode.Failure.execution(message)
            }
            guard let text = outcome["text"] as? String, text.utf8.count <= 80_000 else { throw LocalCode.Failure.invalid }
            return text
        } onCancel: { Task { @MainActor in self.stop() } }
    }
}
