'use strict';

function log(message) {
  console.log('[q3frida] ' + message);
}

function ptrName(ptrValue) {
  try {
    return DebugSymbol.fromAddress(ptrValue).toString();
  } catch (_) {
    return ptrValue.toString();
  }
}

function readCString(ptrValue) {
  if (ptrValue.isNull()) {
    return '(null)';
  }
  try {
    return ptrValue.readUtf8String();
  } catch (error) {
    return ptrValue.toString();
  }
}

function findExport(name) {
  try {
    if (typeof Module.findGlobalExportByName === 'function') {
      return Module.findGlobalExportByName(name);
    }
    return Module.findExportByName(null, name);
  } catch (_) {
    return null;
  }
}

function enumerateSymbols(module) {
  try {
    if (typeof module.enumerateSymbols === 'function') {
      return module.enumerateSymbols();
    }
    return Module.enumerateSymbols(module.name);
  } catch (_) {
    return [];
  }
}

function candidateModules() {
  return Process.enumerateModules().filter((module) => {
    return module.name.indexOf('Quake3') !== -1 ||
      module.name.indexOf('quake3') !== -1 ||
      module.name.indexOf('debug.dylib') !== -1;
  });
}

let symbolIndex = null;

function buildSymbolIndex() {
  const index = new Map();
  for (const module of candidateModules()) {
    for (const symbol of enumerateSymbols(module)) {
      if (!index.has(symbol.name)) {
        index.set(symbol.name, { address: symbol.address, via: module.name + ':' + symbol.name });
      }
      if (symbol.name[0] === '_') {
        const stripped = symbol.name.substring(1);
        if (!index.has(stripped)) {
          index.set(stripped, { address: symbol.address, via: module.name + ':' + symbol.name });
        }
      }
    }
  }
  return index;
}

function findSymbol(name) {
  const names = [name, '_' + name];
  for (const candidate of names) {
    const exported = findExport(candidate);
    if (exported !== null && !exported.isNull()) {
      return { address: exported, via: 'export:' + candidate };
    }
  }

  if (symbolIndex === null) {
    symbolIndex = buildSymbolIndex();
  }
  for (const candidate of names) {
    const indexed = symbolIndex.get(candidate);
    if (indexed !== undefined) {
      return indexed;
    }
  }

  for (const candidate of names) {
    try {
      const debugSymbol = DebugSymbol.fromName(candidate);
      if (debugSymbol.address !== null && !debugSymbol.address.isNull()) {
        return { address: debugSymbol.address, via: 'debug:' + debugSymbol.name };
      }
    } catch (_) {
      // Keep going.
    }
  }

  return null;
}

function traceFunction(name, options) {
  const found = findSymbol(name);
  if (found === null) {
    log('missing ' + name);
    return;
  }

  let count = 0;
  const first = options.first || 4;
  const every = options.every || 1;

  log('trace ' + name + ' @ ' + found.address + ' (' + found.via + ')');
  Interceptor.attach(found.address, {
    onEnter(args) {
      count += 1;
      this.shouldLog = count <= first || (every > 0 && count % every === 0);
      if (this.shouldLog) {
        const detail = options.onEnter ? options.onEnter(args, count) : '';
        log(name + '#' + count + (detail ? ' ' + detail : ''));
      }
    },
    onLeave(retval) {
      if (this.shouldLog && options.onLeave) {
        log(name + ' return ' + options.onLeave(retval));
      }
    }
  });
}

function install() {
  log('pid=' + Process.id + ' arch=' + Process.arch + ' pointerSize=' + Process.pointerSize);
  for (const module of candidateModules()) {
    log('module ' + module.name + ' base=' + module.base + ' size=' + module.size);
  }
  symbolIndex = buildSymbolIndex();
  log('indexed ' + symbolIndex.size + ' symbols');

  traceFunction('Quake3_Init', {
    onEnter: (args) => 'basePath=' + readCString(args[0]),
    onLeave: () => 'void'
  });
  traceFunction('Q3Exec_Command', {
    onEnter: (args) => 'cmd=' + readCString(args[0])
  });
  traceFunction('CL_InitRenderer', {});
  traceFunction('CL_InitCGame', {});
  traceFunction('CL_Frame', {
    first: 5,
    every: 120,
    onEnter: (args) => 'msec=' + args[0].toInt32()
  });
  traceFunction('RE_LoadWorldMap', {
    onEnter: (args) => 'map=' + readCString(args[0])
  });
  traceFunction('LoadWorldMapData', {
    onEnter: (args) => 'map=' + readCString(args[0]),
    onLeave: (retval) => 'ok=' + retval.toInt32()
  });
  traceFunction('RE_BeginFrame', {
    first: 5,
    every: 120,
    onEnter: (args) => 'stereoFrame=' + args[0].toInt32()
  });
  traceFunction('RE_EndFrame', {
    first: 5,
    every: 120
  });
  traceFunction('GLimp_EndFrame', {
    first: 5,
    every: 120
  });
  traceFunction('Com_Error', {
    onEnter: (args) => 'code=' + args[0].toInt32() + ' fmt=' + readCString(args[1])
  });
  traceFunction('Sys_Error', {
    onEnter: (args) => 'fmt=' + readCString(args[0])
  });

  log('probe installed');
}

setImmediate(install);
