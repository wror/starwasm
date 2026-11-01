// repl_worker.mjs — runs the program of a REPL session (host/repl.mjs) in a
// worker thread, so that a program with reactive variables can stay alive
// at the end of its session, blocked waiting for its next line of input.
//
// workerData: bytes (the compiled session), queue ([{src, after}]: the
// session's updates, as host/repl.mjs's updateQueue), flag (an Int32Array's
// SharedArrayBuffer) and port (a MessagePort). Messages to the parent:
//   {out: bytes} / {err: text}   the program's stdout / stderr
//   {idle: true}                 all input so far is consumed: waiting
//   {status}                     the program ended, with this exit status
// To send the next line (a string, or null for the end of input), the
// parent posts it on port, then sets flag[0] to 1 and notifies.
import { parentPort, receiveMessageOnPort, workerData } from "node:worker_threads";
import { loadModule, runModule } from "./wasmhost.mjs";

const { bytes, queue, port } = workerData;
const flag = new Int32Array(workerData.flag);

const status = runModule(loadModule(bytes), {
  stdout: (b) => parentPort.postMessage({ out: Buffer.from(b) }),
  stderr: (t) => parentPort.postMessage({ err: t }),
  readLine(before) {
    // replay: each update at the first sync point past the code before it
    if (queue.length && (before === 0 || queue[0].after < before)) return Buffer.from(queue.shift().src);
    if (before !== 0) return null;
    // the end of the session: wait for the REPL's next update
    parentPort.postMessage({ idle: true });
    Atomics.wait(flag, 0, 0);
    Atomics.store(flag, 0, 0);
    const line = receiveMessageOnPort(port).message;
    return line === null ? null : Buffer.from(line);
  },
});
parentPort.postMessage({ status });
