#!/usr/bin/env node
/**
 * FS25_UsedPlus Codebase Statistics Generator v2.0
 *
 * Generates comprehensive, verified statistics about the codebase.
 * Separates mod code from project support files (docs, tools, etc.)
 * and produces both terminal output and README-ready markdown.
 *
 * Usage:
 *   node codebase_stats.js            # Full terminal report
 *   node codebase_stats.js --markdown  # README-ready markdown snippet
 *
 * Author: Claude & Samantha
 * Version: 2.0.0
 */

const fs = require('fs');
const path = require('path');

const MOD_ROOT = path.dirname(__dirname);

// ─── Terminal colors ──────────────────────────────────────────────────────────
const c = {
    cyan:    '\x1b[96m',
    green:   '\x1b[92m',
    yellow:  '\x1b[93m',
    red:     '\x1b[91m',
    dim:     '\x1b[2m',
    reset:   '\x1b[0m',
    bold:    '\x1b[1m',
};

// ─── Directories to skip entirely ────────────────────────────────────────────
const SKIP_DIRS = new Set([
    'node_modules', '.git', 'dist', '.build_temp',
]);

// ─── "Project support" top-level dirs (not shipped mod code) ─────────────────
const SUPPORT_DIRS = new Set([
    'docs', 'screenshots', 'FS25_AI_Coding_Reference', '.github', 'tools',
]);

// ─── Helpers ──────────────────────────────────────────────────────────────────

function getAllFiles(dir, fileList = []) {
    for (const entry of fs.readdirSync(dir)) {
        const full = path.join(dir, entry);
        const stat = fs.statSync(full);
        if (stat.isDirectory()) {
            if (!SKIP_DIRS.has(entry)) getAllFiles(full, fileList);
        } else {
            fileList.push(full);
        }
    }
    return fileList;
}

function countLines(filePath) {
    try {
        const lines = fs.readFileSync(filePath, 'utf8').split('\n');
        const total = lines.length;
        const code = lines.filter(l => l.trim().length > 0).length;
        return { total, code, blank: total - code };
    } catch {
        return { total: 0, code: 0, blank: 0 };
    }
}

function n(filePath) {
    // Normalize to forward slashes for consistent matching
    return path.relative(MOD_ROOT, filePath).replace(/\\/g, '/');
}

function ext(filePath) {
    return path.extname(filePath).toLowerCase() || '(none)';
}

function formatBytes(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + ' MB';
    return (bytes / 1073741824).toFixed(1) + ' GB';
}

function formatNum(num) {
    return num.toLocaleString();
}

function topDir(relPath) {
    const parts = relPath.split('/');
    return parts.length > 1 ? parts[0] : '(root)';
}

function isModCode(relPath) {
    const top = topDir(relPath);
    return !SUPPORT_DIRS.has(top);
}

// ─── Data collection ──────────────────────────────────────────────────────────

function collectData() {
    const allFiles = getAllFiles(MOD_ROOT);
    const data = {
        allFiles: [],
        modFiles: [],
        supportFiles: [],
        byExt: {},           // ext → { files: [], lines: {total,code,blank} }
        byDir: {},            // top-level dir → count
        luaFiles: [],         // { rel, lines } for all Lua
    };

    for (const filePath of allFiles) {
        const rel = n(filePath);
        const e = ext(filePath);
        const top = topDir(rel);
        const isMod = isModCode(rel);

        data.allFiles.push({ rel, filePath, ext: e, isMod });
        if (isMod) data.modFiles.push({ rel, filePath, ext: e });
        else data.supportFiles.push({ rel, filePath, ext: e });

        // By extension
        if (!data.byExt[e]) data.byExt[e] = { files: [], lines: { total: 0, code: 0, blank: 0 } };
        data.byExt[e].files.push(rel);

        // Count lines for text-based code files (skip JSON — inflated by lock files)
        if (['.lua', '.js', '.xml', '.md', '.yml', '.ps1', '.sh', '.bat'].includes(e)) {
            const lines = countLines(filePath);
            data.byExt[e].lines.total += lines.total;
            data.byExt[e].lines.code += lines.code;
            data.byExt[e].lines.blank += lines.blank;

            if (e === '.lua') {
                data.luaFiles.push({ rel, lines: lines.code });
            }
        }

        // By directory
        data.byDir[top] = (data.byDir[top] || 0) + 1;
    }

    return data;
}

// ─── Feature counting (verified patterns) ─────────────────────────────────────

function countFeatures(data) {
    const luaRels = data.allFiles.filter(f => f.ext === '.lua').map(f => f.rel);
    const xmlRels = data.allFiles.filter(f => f.ext === '.xml').map(f => f.rel);

    // GUI XML — all XML files in gui/ directory
    const guiXml = xmlRels.filter(f => f.startsWith('gui/') && f.endsWith('.xml'));
    const dialogXml = guiXml.filter(f => f.includes('Dialog'));
    const frameXml = guiXml.filter(f => f.includes('Frame'));
    const otherGuiXml = guiXml.filter(f => !f.includes('Dialog') && !f.includes('Frame'));

    // GUI Lua — all Lua files in src/gui/
    const guiLua = luaRels.filter(f => f.startsWith('src/gui/'));
    const dialogLua = guiLua.filter(f => f.includes('Dialog'));

    // Managers — all Lua files in src/managers/ (including sub-directories)
    const managers = luaRels.filter(f => f.startsWith('src/managers/'));

    // Events — all Lua files in src/events/
    const events = luaRels.filter(f => f.startsWith('src/events/'));

    // Specializations — all Lua files in src/specializations/
    const specs = luaRels.filter(f => f.startsWith('src/specializations/'));

    // Extensions — all Lua files in src/extensions/
    const extensions = luaRels.filter(f => f.startsWith('src/extensions/'));

    // Utilities — all Lua files in src/utils/
    const utilities = luaRels.filter(f => f.startsWith('src/utils/'));

    // Vehicle scripts — Lua files in vehicles/ root
    const vehicleScripts = luaRels.filter(f => f.startsWith('vehicles/') && f.endsWith('.lua'));

    // Core — Lua files in src/core/ and src/data/
    const coreFiles = luaRels.filter(f => f.startsWith('src/core/') || f.startsWith('src/data/'));

    // Translation files — XML files matching translations/translation_*.xml
    const translationFiles = xmlRels.filter(f => /^translations\/translation_\w+\.xml$/.test(f));

    // Translation key count from English file
    let translationKeys = 0;
    const enFile = path.join(MOD_ROOT, 'translations', 'translation_en.xml');
    if (fs.existsSync(enFile)) {
        const content = fs.readFileSync(enFile, 'utf8');
        const matches = content.match(/<e k="/g);
        translationKeys = matches ? matches.length : 0;
    }

    // Icons — PNG files in gui/icons/
    const icons = data.allFiles.filter(f => f.rel.startsWith('gui/icons/') && f.ext === '.png');

    // Assets
    const ddsFiles = data.allFiles.filter(f => f.ext === '.dds');
    const i3dFiles = data.allFiles.filter(f => f.ext === '.i3d');
    const shapeFiles = data.allFiles.filter(f => f.ext === '.shapes');

    // Tools
    const toolFiles = data.allFiles.filter(f => f.rel.startsWith('tools/'));

    return {
        guiXml, dialogXml, frameXml, otherGuiXml,
        guiLua, dialogLua,
        managers, events, specs, extensions, utilities,
        vehicleScripts, coreFiles,
        translationFiles, translationKeys,
        icons, ddsFiles, i3dFiles, shapeFiles, toolFiles,
    };
}

// ─── Per-category line counts (for detailed breakdown) ────────────────────────

function categoryLines(fileList) {
    let total = 0;
    const perFile = [];
    for (const rel of fileList) {
        const lines = countLines(path.join(MOD_ROOT, rel));
        total += lines.code;
        perFile.push({ rel: path.basename(rel, '.lua'), lines: lines.code });
    }
    perFile.sort((a, b) => b.lines - a.lines);
    return { total, perFile };
}

// ─── Terminal output ──────────────────────────────────────────────────────────

function printTerminal(data, features) {
    const lua = data.byExt['.lua']?.lines || { total: 0, code: 0, blank: 0 };
    const xml = data.byExt['.xml']?.lines || { total: 0, code: 0, blank: 0 };
    const js  = data.byExt['.js']?.lines  || { total: 0, code: 0, blank: 0 };
    const totalCode = lua.code + xml.code + js.code;
    const totalSize = data.allFiles.reduce((sum, f) => {
        try { return sum + fs.statSync(f.filePath).size; } catch { return sum; }
    }, 0);

    console.log();
    console.log(c.cyan + '═══════════════════════════════════════════════════════════════════════');
    console.log('  FS25_UsedPlus — Codebase Statistics v2.0');
    console.log('═══════════════════════════════════════════════════════════════════════' + c.reset);

    // ── Overall Summary ──
    console.log();
    console.log(c.bold + '  OVERALL SUMMARY' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    console.log(`  Total Files:        ${formatNum(data.allFiles.length)}`);
    console.log(`    Mod Code:         ${formatNum(data.modFiles.length)}`);
    console.log(`    Project Support:  ${formatNum(data.supportFiles.length)} ${c.dim}(docs, tools, .github, etc.)${c.reset}`);
    console.log(`  Total Size:         ${formatBytes(totalSize)}`);

    // ── Code Metrics ──
    console.log();
    console.log(c.bold + '  CODE METRICS' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    console.log(`  Lua:                ${formatNum(lua.code)} lines  ${c.dim}(${data.byExt['.lua']?.files.length || 0} files)${c.reset}`);
    console.log(`  XML:                ${formatNum(xml.code)} lines  ${c.dim}(${data.byExt['.xml']?.files.length || 0} files)${c.reset}`);
    console.log(`  JavaScript:         ${formatNum(js.code)} lines  ${c.dim}(${data.byExt['.js']?.files.length || 0} files)${c.reset}`);
    console.log(`  ${c.green}Total Code:         ${formatNum(totalCode)} lines${c.reset}`);

    // ── Files by Type ──
    console.log();
    console.log(c.bold + '  FILES BY TYPE' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    console.log(`  ${c.dim}${'Type'.padEnd(12)} ${'Count'.padStart(5)}   Lines (Code / Blank)${c.reset}`);

    const sorted = Object.entries(data.byExt).sort((a, b) => b[1].files.length - a[1].files.length);
    for (const [ext, info] of sorted) {
        const count = String(info.files.length).padStart(5);
        if (info.lines.total > 0) {
            console.log(`  ${ext.padEnd(12)} ${count}   ${formatNum(info.lines.code).padStart(7)} / ${formatNum(info.lines.blank).padStart(5)}`);
        } else {
            console.log(`  ${ext.padEnd(12)} ${count}   ${c.dim}(binary)${c.reset}`);
        }
    }

    // ── Architecture ──
    console.log();
    console.log(c.bold + '  ARCHITECTURE' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    console.log(`  GUI Screens:        ${features.guiXml.length} XML  ${c.dim}(${features.dialogXml.length} dialogs, ${features.frameXml.length} frames, ${features.otherGuiXml.length} panels)${c.reset}`);
    console.log(`  GUI Lua:            ${features.guiLua.length} files  ${c.dim}(${features.dialogLua.length} dialog controllers)${c.reset}`);
    console.log(`  Managers:           ${features.managers.length} files`);
    console.log(`  Network Events:     ${features.events.length} files`);
    console.log(`  Specializations:    ${features.specs.length} files`);
    console.log(`  Extensions:         ${features.extensions.length} files`);
    console.log(`  Utilities:          ${features.utilities.length} files`);
    console.log(`  Vehicle Scripts:    ${features.vehicleScripts.length} files`);
    console.log(`  Core/Data:          ${features.coreFiles.length} files`);

    // ── Assets ──
    console.log();
    console.log(c.bold + '  ASSETS' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    console.log(`  DDS Textures:       ${features.ddsFiles.length}`);
    console.log(`  GUI Icons (PNG):    ${features.icons.length}`);
    console.log(`  3D Models (I3D):    ${features.i3dFiles.length}`);
    console.log(`  Shape Files:        ${features.shapeFiles.length}`);

    // ── Localization ──
    console.log();
    console.log(c.bold + '  LOCALIZATION' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    console.log(`  Languages:          ${features.translationFiles.length}`);
    console.log(`  Translation Keys:   ${formatNum(features.translationKeys)}`);

    // ── Top 10 Largest Lua Files ──
    console.log();
    console.log(c.bold + '  TOP 10 LARGEST LUA FILES' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    const top10 = data.luaFiles.sort((a, b) => b.lines - a.lines).slice(0, 10);
    for (let i = 0; i < top10.length; i++) {
        const f = top10[i];
        const name = path.basename(f.rel, '.lua');
        const warn = f.lines > 1500 ? ` ${c.red}⚠ EXCEEDS 1500 LINE LIMIT${c.reset}` : '';
        console.log(`  ${String(i + 1).padStart(2)}. ${name.padEnd(35)} ${formatNum(f.lines).padStart(6)} lines${warn}`);
    }

    // ── Detailed Category Breakdowns ──
    console.log();
    console.log(c.bold + '  DETAILED CATEGORY BREAKDOWNS' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);

    const categories = [
        ['Managers', features.managers],
        ['Events', features.events],
        ['Specializations', features.specs],
        ['Extensions', features.extensions],
        ['Utilities', features.utilities],
    ];

    for (const [label, files] of categories) {
        const cl = categoryLines(files);
        const topFiles = cl.perFile.slice(0, 4).map(f => `${f.rel} (${formatNum(f.lines)})`).join(' • ');
        console.log(`  ${c.yellow}${label}${c.reset} (${formatNum(cl.total)} lines):`);
        console.log(`    ${topFiles}`);
    }

    // ── Directory Breakdown ──
    console.log();
    console.log(c.bold + '  FILES BY DIRECTORY' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    const sortedDirs = Object.entries(data.byDir).sort((a, b) => b[1] - a[1]);
    for (const [dir, count] of sortedDirs) {
        const tag = SUPPORT_DIRS.has(dir) ? ` ${c.dim}(support)${c.reset}` : '';
        console.log(`  ${dir.padEnd(30)} ${String(count).padStart(4)} files${tag}`);
    }

    // ── Development Tools ──
    console.log();
    console.log(c.bold + '  DEVELOPMENT TOOLS' + c.reset);
    console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
    console.log(`  Tool Scripts:       ${features.toolFiles.length} files`);

    console.log();
    console.log(c.cyan + '═══════════════════════════════════════════════════════════════════════' + c.reset);
    console.log();
}

// ─── Markdown output (for README.md) ──────────────────────────────────────────

function printMarkdown(data, features) {
    const lua = data.byExt['.lua']?.lines || { total: 0, code: 0, blank: 0 };
    const xml = data.byExt['.xml']?.lines || { total: 0, code: 0, blank: 0 };
    const js  = data.byExt['.js']?.lines  || { total: 0, code: 0, blank: 0 };
    const totalCode = lua.code + xml.code + js.code;

    const luaCount = data.byExt['.lua']?.files.length || 0;
    const xmlCount = data.byExt['.xml']?.files.length || 0;

    const out = [];
    out.push('### Codebase Statistics');
    out.push('');
    out.push(`- **${formatNum(totalCode)} lines of code** (${formatNum(lua.code)} Lua • ${formatNum(xml.code)} XML • ${formatNum(js.code)} JavaScript)`);
    out.push(`- **${formatNum(data.modFiles.length)} mod files** (${luaCount} Lua • ${xmlCount} XML • ${features.icons.length} icons • ${features.ddsFiles.length} textures • ${features.i3dFiles.length} 3D models)`);
    out.push(`- **${features.guiXml.length} GUI screens** (${features.dialogXml.length} dialogs, ${features.frameXml.length} frames, ${features.otherGuiXml.length} panels)`);
    out.push(`- **${features.managers.length} manager classes** orchestrating game systems`);
    out.push(`- **${features.events.length} network event modules** for multiplayer sync`);
    out.push(`- **${features.specs.length} specialization modules** for maintenance systems`);
    out.push(`- **${features.extensions.length} extension hooks** into base game systems`);
    out.push(`- **${features.utilities.length} utility/helper modules** for shared logic`);
    out.push(`- **${features.toolFiles.length} development tools** for build, validation & stats`);
    out.push(`- **${formatNum(features.translationKeys)} localization keys** translated to ${features.translationFiles.length} languages`);
    out.push(`- **5 months development** (November 2025 - present)`);
    out.push('');

    // Detailed breakdown
    out.push('<details>');
    out.push('<summary><b>📊 Detailed Architecture Breakdown</b></summary>');
    out.push('');

    const categories = [
        ['Manager Layer', features.managers],
        ['Network Events', features.events],
        ['Specializations', features.specs],
        ['Extensions', features.extensions],
        ['Utilities', features.utilities],
    ];

    for (const [label, files] of categories) {
        const cl = categoryLines(files);
        const topFiles = cl.perFile.slice(0, 4).map(f => `${f.rel} (${formatNum(f.lines)})`).join(' • ');
        out.push(`**${label}** (${formatNum(cl.total)} lines):`);
        out.push(`- ${topFiles}`);
        out.push('');
    }

    // Dialog categories — count by name pattern
    const dialogCategories = {
        'Finance System': features.dialogLua.filter(f => /Finance|Loan|Credit|Payment|Lease|Repossession|Deal/.test(f)),
        'Marketplace - Buying': features.dialogLua.filter(f => /Search|Used|Preview|Inspection|Negotiation/.test(f)),
        'Marketplace - Selling': features.dialogLua.filter(f => /Sale|Sell|Offer/.test(f)),
        'Maintenance & Repair': features.dialogLua.filter(f => /Repair|Maintenance|Fluid|Tire|FaultTracer/.test(f)),
        'Service Truck': features.dialogLua.filter(f => /ServiceTruck/.test(f)),
        'Purchase System': features.dialogLua.filter(f => /Purchase|UnifiedLand/.test(f)),
    };

    out.push('**Dialog Categories**:');
    const cats = Object.entries(dialogCategories).filter(([, v]) => v.length > 0);
    out.push('- ' + cats.map(([k, v]) => `${k} (${v.length})`).join(' • '));
    out.push('');
    out.push('</details>');

    console.log(out.join('\n'));
}

// ─── Main ─────────────────────────────────────────────────────────────────────

function main() {
    const markdownMode = process.argv.includes('--markdown');

    const data = collectData();
    const features = countFeatures(data);

    if (markdownMode) {
        printMarkdown(data, features);
    } else {
        printTerminal(data, features);

        // Also show the markdown snippet at the end for convenience
        console.log(c.bold + '  README-READY MARKDOWN (copy below):' + c.reset);
        console.log(c.dim + '  ─────────────────────────────────────────────────────' + c.reset);
        console.log();
        printMarkdown(data, features);
    }
}

main();
