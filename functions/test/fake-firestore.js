/* In-memory Firestore fake for the Cloud Functions unit tests.
 *
 * Used by functions/test/orders.test.js, discounts.test.js, and
 * audit.test.js. Runs the REAL lib code (validation.js, orders.js,
 * feedback.js, sweep.js) — only the Firestore interface is fake.
 *
 * Fidelity notes (what it models, honestly):
 * - runTransaction serializes concurrent transactions with a mutex, so
 *   two simultaneous calls see each other's committed writes — the same
 *   outcome Firestore's serializable transactions give (T3/T4/T17).
 *   Writes inside a transaction are buffered and applied only on
 *   success, so a thrown error rolls the whole transaction back (T8).
 * - set/update/delete, where(field, '==', value), orderBy, limit.
 * - serverTimestamp() is NOT modeled: the lib code receives an injected
 *   serverTimestamp function returning a plain ms number in tests.
 * What it does NOT model (covered by the emulator rules tests instead):
 * - Firestore Security Rules (anonymous reads, audit enforcement).
 * - Composite indexes, real contention aborts/retries, server
 *   timestamps as Timestamp objects.
 */

function createFakeFirestore() {
  const store = new Map(); /* full doc path -> plain data object */
  let autoIdCounter = 0;
  let txQueue = Promise.resolve(); /* serializes transactions */

  const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
  const getPathValue = (obj, path) => path.split('.').reduce(
    (cur, key) => (cur && typeof cur === 'object' ? cur[key] : undefined), obj,
  );

  function docRef(path) {
    return {
      __path: path,
      get id() { return path.split('/').pop(); },
      get: async () => {
        const data = store.get(path);
        return { exists: data !== undefined, id: path.split('/').pop(), data: () => clone(data) };
      },
      set: async (data, options) => {
        const prev = store.get(path) || {};
        store.set(path, options && options.merge ? { ...clone(prev), ...clone(data) } : clone(data));
      },
      update: async (data) => {
        if (!store.has(path)) throw new Error(`update on missing doc ${path}`);
        store.set(path, { ...clone(store.get(path)), ...clone(data) });
      },
      delete: async () => { store.delete(path); },
      collection: (name) => collectionRef(`${path}/${name}`),
    };
  }

  function collectionRef(path) {
    return {
      __path: path,
      doc: (id) => {
        if (id === undefined || id === null) {
          autoIdCounter += 1;
          id = `auto_${autoIdCounter}`;
        }
        return docRef(`${path}/${id}`);
      },
      where: (field, op, value) => new Query(path).where(field, op, value),
      orderBy: (field, dir) => new Query(path).orderBy(field, dir),
      limit: (n) => new Query(path).limit(n),
      get: async () => new Query(path).get(),
    };
  }

  class Query {
    constructor(path) { this.path = path; this.filters = []; this.order = null; this.limitN = null; }
    where(field, op, value) { this.filters.push({ field, op, value }); return this; }
    orderBy(field, dir = 'asc') { this.order = { field, dir }; return this; }
    limit(n) { this.limitN = n; return this; }
    async get() {
      let docs = [...store.entries()]
        .filter(([p]) => p.startsWith(`${this.path}/`) && !p.slice(this.path.length + 1).includes('/'))
        .map(([p, d]) => ({ id: p.slice(this.path.length + 1), data: () => clone(d), exists: true }));
      for (const f of this.filters) {
        if (f.op !== '==') throw new Error(`fake query: unsupported op ${f.op}`);
        docs = docs.filter((d) => getPathValue(d.data(), f.field) === f.value);
      }
      if (this.order) {
        const { field, dir } = this.order;
        docs.sort((a, b) => {
          const av = getPathValue(a.data(), field);
          const bv = getPathValue(b.data(), field);
          if (av === bv) return 0;
          return (av < bv ? -1 : 1) * (dir === 'desc' ? -1 : 1);
        });
      }
      if (this.limitN !== null) docs = docs.slice(0, this.limitN);
      return { docs };
    }
  }

  /* Transaction: buffers writes, applies them only on success. */
  function makeTx() {
    const pending = new Map(); /* path -> data | null (null = delete) */
    const tx = {
      get: async (ref) => {
        if (pending.has(ref.__path)) {
          const data = pending.get(ref.__path);
          return { exists: data !== null && data !== undefined, id: ref.id, data: () => clone(data) };
        }
        const data = store.get(ref.__path);
        return { exists: data !== undefined, id: ref.id, data: () => clone(data) };
      },
      set: (ref, data, options) => {
        const prev = pending.has(ref.__path)
          ? pending.get(ref.__path)
          : store.get(ref.__path);
        const base = prev || {};
        pending.set(ref.__path, options && options.merge ? { ...clone(base), ...clone(data) } : clone(data));
      },
      update: (ref, data) => {
        const prev = pending.has(ref.__path) ? pending.get(ref.__path) : store.get(ref.__path);
        if (prev === undefined || prev === null) throw new Error(`update on missing doc ${ref.__path}`);
        pending.set(ref.__path, { ...clone(prev), ...clone(data) });
      },
      delete: (ref) => { pending.set(ref.__path, null); },
      __commit() {
        for (const [path, data] of pending.entries()) {
          if (data === null) store.delete(path);
          else store.set(path, data);
        }
      },
    };
    return tx;
  }

  const db = {
    store,
    collection: (name) => collectionRef(name),
    doc: (path) => docRef(path),
    runTransaction: async (fn) => {
      /* Serialize: each transaction waits for the previous one to
       * finish (commit or abort) before starting. */
      let release;
      const lock = new Promise((resolve) => { release = resolve; });
      const prev = txQueue;
      txQueue = txQueue.then(() => lock);
      await prev;
      try {
        const tx = makeTx();
        const result = await fn(tx);
        tx.__commit();
        return result;
      } finally {
        release();
      }
    },
    batch: () => {
      const ops = [];
      return {
        set: (ref, data, options) => { ops.push(['set', ref, data, options]); },
        update: (ref, data) => { ops.push(['update', ref, data]); },
        delete: (ref) => { ops.push(['delete', ref]); },
        commit: async () => {
          for (const [op, ref, data, options] of ops) {
            if (op === 'set') await ref.set(data, options);
            else if (op === 'update') await ref.update(data);
            else await ref.delete();
          }
        },
      };
    },
    /* Test helpers: seed + inspect. */
    seed: (path, data) => { store.set(path, clone(data)); },
    all: (prefix) => [...store.entries()]
      .filter(([p]) => p.startsWith(prefix))
      .map(([p, d]) => ({ id: p.slice(prefix.length), data: clone(d) })),
  };
  return db;
}

module.exports = { createFakeFirestore };
