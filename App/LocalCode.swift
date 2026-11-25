import Foundation

enum LocalCode {
    struct Recipe: Codable, Equatable {
        let name, code: String
        static func decode(_ raw: String) throws -> Self {
            guard raw.utf8.count <= 12_000, let data = raw.data(using: .utf8), let recipe = try? JSONDecoder().decode(Self.self, from: data),
                  !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, recipe.name.count <= 100,
                  !recipe.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, recipe.code.utf8.count <= 8_000 else { throw Failure.invalid }
            return recipe
        }
    }
    struct Output: Decodable { let ok: Bool; let text: String?; let error: String? }
    enum Failure: LocalizedError {
        case invalid, timeout, stopped, execution(String)
        var errorDescription: String? { switch self {
        case .invalid: "Koden eller resultatet kunne ikke bruges. Højst 8 KB kode og 80 KB resultat."
        case .timeout: "Scriptet tog for lang tid og blev stoppet. Forkort beregningen, og prøv igen."
        case .stopped: "Scriptet blev stoppet."
        case .execution(let message): "Scriptet fejlede: " + String(message.prefix(300))
        } }
    }
    static func output(_ raw: String) throws -> String {
        guard raw.utf8.count <= 100_000, let data = raw.data(using: .utf8), let value = try? JSONDecoder().decode(Output.self, from: data) else { throw Failure.invalid }
        if !value.ok {
            if value.error == "timeout" { throw Failure.timeout }; if value.error == "cancelled" { throw Failure.stopped }
            throw Failure.execution(value.error ?? "Ukendt fejl")
        }
        guard let text = value.text, !text.isEmpty, text.utf8.count <= 80_000 else { throw Failure.invalid }; return text
    }
    static func command(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["lav et lokalt værktøj:", "lav lokal kode:", "kør lokal kode:"] where clean.lowercased().hasPrefix(prefix) { return String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        return nil
    }
    static func linuxCommand(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["åbn linux", "åbn terminalen"].contains(clean.lowercased()) { return "" }
        for prefix in ["kør linux:", "brug terminalen:", "kør i terminalen:"] where clean.lowercased().hasPrefix(prefix) {
            return String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    static let worker = #"""
    self.onmessage = async (event) => {
      try {
        const {code, input} = event.data;
        const run = new Function('input', '"use strict";\n' + code);
        const value = await run(input);
        const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
        if (typeof text !== 'string' || !text.length || new TextEncoder().encode(text).length > 80000) throw new Error('Returner tekst eller JSON, højst 80 KB.');
        self.postMessage({ok:true, text});
      } catch (error) { self.postMessage({ok:false, error:String(error.message || error).slice(0,300)}); }
    };
    """#
    static var page: String {
        let encoded = String(data: try! JSONEncoder().encode(worker), encoding: .utf8)!
        return #"""
        <!doctype html><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' blob:; worker-src blob:; connect-src 'none'; img-src 'none'; form-action 'none'; base-uri 'none'">
        <script>
        let active = null;
        window.cancelRun = () => { if (active) active({ok:false,error:'cancelled'}); };
        window.runCode = (code, input) => new Promise(resolve => {
          window.cancelRun();
          let worker, timer, address;
          const finish = value => {
            clearTimeout(timer); if (worker) worker.terminate(); if (address) URL.revokeObjectURL(address);
            active = null; resolve(JSON.stringify(value));
          };
          active = finish;
          try {
            address = URL.createObjectURL(new Blob([__WORKER_JSON__], {type:'text/javascript'}));
            worker = new Worker(address);
            worker.onmessage = event => finish(event.data);
            worker.onerror = event => { event.preventDefault(); finish({ok:false,error:event.message || 'Script error'}); };
            timer = setTimeout(() => finish({ok:false,error:'timeout'}), 3000);
            worker.postMessage({code,input});
          } catch (error) { finish({ok:false,error:String(error.message || error)}); }
        });
        </script>
        """#.replacingOccurrences(of: "__WORKER_JSON__", with: encoded)
    }
}
