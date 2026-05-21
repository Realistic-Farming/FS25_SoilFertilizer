#!/usr/bin/env node
/**
 * FS25_UsedPlus - Find Unused Code Scanner
 *
 * Scans the codebase for potentially orphaned:
 * - Lua files not registered in modDesc.xml
 * - Dialog files (.lua + .xml) not called by DialogLoader or getInstance
 * - Functions defined but never referenced elsewhere
 *
 * Usage:
 *   node find_unused.js [--verbose] [--check-functions]
 *
 * Author: Claude & Samantha
 * Version: 1.3.0 - Added vanilla hooks, event subscriptions, vehicle metrics, malfunctions
 */

const fs = require('fs');
const path = require('path');

// ANSI colors
const colors = {
    red: '\x1b[91m',
    green: '\x1b[92m',
    yellow: '\x1b[93m',
    blue: '\x1b[94m',
    cyan: '\x1b[96m',
    reset: '\x1b[0m',
    bold: '\x1b[1m'
};

/**
 * Find the mod root directory (where modDesc.xml lives)
 */
function getModRoot() {
    let dir = __dirname;

    // Go up from tools/ to mod root
    const parentDir = path.dirname(dir);
    if (fs.existsSync(path.join(parentDir, 'modDesc.xml'))) {
        return parentDir;
    }

    // Try current directory
    if (fs.existsSync('modDesc.xml')) {
        return process.cwd();
    }

    console.error(`${colors.red}Error: Cannot find modDesc.xml${colors.reset}`);
    process.exit(1);
}

/**
 * Parse modDesc.xml and get registered source files
 */
function parseModDescSources(modRoot) {
    const modDescPath = path.join(modRoot, 'modDesc.xml');
    const content = fs.readFileSync(modDescPath, 'utf8');

    const registered = new Set();
    const regex = /sourceFile\s+filename="([^"]+)"/g;
    let match;

    while ((match = regex.exec(content)) !== null) {
        registered.add(match[1].replace(/\//g, path.sep));
    }

    return registered;
}

/**
 * Recursively find all files matching a pattern
 */
function findFiles(dir, pattern, results = []) {
    if (!fs.existsSync(dir)) return results;

    const files = fs.readdirSync(dir);
    for (const file of files) {
        const filePath = path.join(dir, file);
        const stat = fs.statSync(filePath);

        if (stat.isDirectory()) {
            findFiles(filePath, pattern, results);
        } else if (pattern.test(file)) {
            results.push(filePath);
        }
    }

    return results;
}

/**
 * Find all Lua files in src/
 */
function findAllLuaFiles(modRoot) {
    const srcDir = path.join(modRoot, 'src');
    const files = findFiles(srcDir, /\.lua$/);

    return new Set(files.map(f => path.relative(modRoot, f)));
}

/**
 * Find all dialog files (paired .lua and .xml)
 */
function findAllDialogs(modRoot) {
    const dialogs = {};

    // Find Lua dialog files in src/gui
    const guiDir = path.join(modRoot, 'src', 'gui');
    if (fs.existsSync(guiDir)) {
        const luaFiles = findFiles(guiDir, /Dialog\.lua$/);
        for (const file of luaFiles) {
            const name = path.basename(file, '.lua');
            dialogs[name] = { lua: file, xml: null };
        }
    }

    // Find XML dialog files in gui/
    const xmlDir = path.join(modRoot, 'gui');
    if (fs.existsSync(xmlDir)) {
        const xmlFiles = findFiles(xmlDir, /Dialog\.xml$/);
        for (const file of xmlFiles) {
            const name = path.basename(file, '.xml');
            if (dialogs[name]) {
                dialogs[name].xml = file;
            } else {
                dialogs[name] = { lua: null, xml: file };
            }
        }
    }

    return dialogs;
}

/**
 * Search for references to a dialog in all Lua files
 * v1.0.1: Now searches src/, vehicles/, placeables/ directories
 */
function searchDialogReferences(modRoot, dialogName) {
    const patterns = [
        new RegExp(`DialogLoader\\.show\\s*\\(\\s*["']?${dialogName}["']?`),
        new RegExp(`DialogLoader\\.register\\s*\\(\\s*["']${dialogName}["']`),
        new RegExp(`${dialogName}\\.getInstance`),
        new RegExp(`${dialogName}\\.show`),
        new RegExp(`${dialogName}\\.new`),
        new RegExp(`g_gui:loadGui\\s*\\([^,]+,\\s*["']?${dialogName}["']?`),
        new RegExp(`g_gui:showDialog\\s*\\(\\s*["']${dialogName}["']`),
        new RegExp(`showDialog\\s*\\(\\s*["']?${dialogName}["']?`)
    ];

    // Search multiple directories - v1.0.1
    const searchDirs = ['src', 'vehicles', 'placeables'];
    let luaFiles = [];
    for (const dir of searchDirs) {
        const dirPath = path.join(modRoot, dir);
        if (fs.existsSync(dirPath)) {
            luaFiles = luaFiles.concat(findFiles(dirPath, /\.lua$/));
        }
    }

    const references = [];

    for (const file of luaFiles) {
        // Skip the dialog's own file
        if (path.basename(file, '.lua') === dialogName) continue;

        try {
            const content = fs.readFileSync(file, 'utf8');
            for (const pattern of patterns) {
                if (pattern.test(content)) {
                    references.push(path.relative(modRoot, file));
                    break;
                }
            }
        } catch (e) {
            // Ignore read errors
        }
    }

    return references;
}

/**
 * Count lines of code in a file (excluding blank lines and comments)
 */
function countLinesOfCode(filePath) {
    try {
        const content = fs.readFileSync(filePath, 'utf8');
        const lines = content.split('\n');
        let codeLines = 0;
        let commentLines = 0;
        let blankLines = 0;
        let inBlockComment = false;

        for (const line of lines) {
            const trimmed = line.trim();

            // Blank line
            if (trimmed === '') {
                blankLines++;
                continue;
            }

            // Block comment handling (Lua uses --[[ ]])
            if (inBlockComment) {
                commentLines++;
                if (trimmed.includes(']]')) {
                    inBlockComment = false;
                }
                continue;
            }

            // Start of block comment
            if (trimmed.startsWith('--[[')) {
                commentLines++;
                if (!trimmed.includes(']]')) {
                    inBlockComment = true;
                }
                continue;
            }

            // Single line comment
            if (trimmed.startsWith('--')) {
                commentLines++;
                continue;
            }

            codeLines++;
        }

        return { total: lines.length, code: codeLines, comments: commentLines, blank: blankLines };
    } catch (e) {
        return { total: 0, code: 0, comments: 0, blank: 0 };
    }
}

/**
 * Get file size in a human-readable format
 */
function formatFileSize(bytes) {
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(2) + ' MB';
}

/**
 * Gather codebase statistics
 */
function gatherStatistics(modRoot) {
    const stats = {
        lua: {
            total: 0,
            byCategory: {},
            totalLines: 0,
            codeLines: 0,
            commentLines: 0,
            blankLines: 0,
            totalSize: 0,
            largestFiles: []
        },
        xml: {
            total: 0,
            gui: 0,
            translations: 0,
            other: 0,
            totalSize: 0
        },
        dialogs: 0,
        events: 0,
        managers: 0,
        extensions: 0,
        specializations: 0,
        utils: 0
    };

    // Categories to track
    const categories = {
        'src/gui': 'GUI Screens',
        'src/gui/financepanels': 'Finance Panels',
        'src/events': 'Network Events',
        'src/managers': 'Managers',
        'src/managers/usedvehicle': 'Used Vehicle Modules',
        'src/extensions': 'Extensions',
        'src/specializations': 'Specializations',
        'src/specializations/maintenance': 'Maintenance Modules',
        'src/utils': 'Utilities',
        'src/data': 'Data Classes',
        'src/settings': 'Settings',
        'src/core': 'Core',
        'vehicles': 'Vehicles',
        'placeables': 'Placeables'
    };

    // Initialize categories
    for (const cat of Object.values(categories)) {
        stats.lua.byCategory[cat] = { files: 0, lines: 0 };
    }
    stats.lua.byCategory['Other'] = { files: 0, lines: 0 };

    // Scan all Lua files
    const luaDirs = ['src', 'vehicles', 'placeables'];
    const allLuaFiles = [];

    for (const dir of luaDirs) {
        const dirPath = path.join(modRoot, dir);
        if (fs.existsSync(dirPath)) {
            const files = findFiles(dirPath, /\.lua$/);
            allLuaFiles.push(...files);
        }
    }

    for (const file of allLuaFiles) {
        const relPath = path.relative(modRoot, file).replace(/\\/g, '/');
        const fileStat = fs.statSync(file);
        const lineStats = countLinesOfCode(file);

        stats.lua.total++;
        stats.lua.totalLines += lineStats.total;
        stats.lua.codeLines += lineStats.code;
        stats.lua.commentLines += lineStats.comments;
        stats.lua.blankLines += lineStats.blank;
        stats.lua.totalSize += fileStat.size;

        // Track largest files
        stats.lua.largestFiles.push({
            name: path.basename(file),
            path: relPath,
            lines: lineStats.total,
            code: lineStats.code,
            size: fileStat.size
        });

        // Categorize
        let categorized = false;
        for (const [prefix, catName] of Object.entries(categories)) {
            if (relPath.startsWith(prefix)) {
                // Use most specific match
                const currentDepth = prefix.split('/').length;
                let foundBetter = false;
                for (const [otherPrefix, otherCat] of Object.entries(categories)) {
                    if (relPath.startsWith(otherPrefix) &&
                        otherPrefix.split('/').length > currentDepth) {
                        foundBetter = true;
                        break;
                    }
                }
                if (!foundBetter) {
                    stats.lua.byCategory[catName].files++;
                    stats.lua.byCategory[catName].lines += lineStats.code;
                    categorized = true;
                    break;
                }
            }
        }
        if (!categorized) {
            stats.lua.byCategory['Other'].files++;
            stats.lua.byCategory['Other'].lines += lineStats.code;
        }

        // Count specific types
        const fileName = path.basename(file);
        if (fileName.endsWith('Dialog.lua')) stats.dialogs++;
        if (fileName.endsWith('Event.lua') || fileName.endsWith('Events.lua')) stats.events++;
        if (fileName.endsWith('Manager.lua')) stats.managers++;
        if (fileName.endsWith('Extension.lua')) stats.extensions++;
    }

    // Sort largest files
    stats.lua.largestFiles.sort((a, b) => b.lines - a.lines);
    stats.lua.largestFiles = stats.lua.largestFiles.slice(0, 10);

    // Count XML files
    const xmlDirs = ['gui', 'translations'];
    for (const dir of xmlDirs) {
        const dirPath = path.join(modRoot, dir);
        if (fs.existsSync(dirPath)) {
            const files = findFiles(dirPath, /\.xml$/);
            for (const file of files) {
                const fileStat = fs.statSync(file);
                stats.xml.total++;
                stats.xml.totalSize += fileStat.size;

                if (dir === 'gui') stats.xml.gui++;
                else if (dir === 'translations') stats.xml.translations++;
                else stats.xml.other++;
            }
        }
    }

    return stats;
}

/**
 * Print codebase statistics
 */
function printStatistics(stats) {
    console.log(`\n${colors.bold}${colors.blue}=== Codebase Statistics ===${colors.reset}\n`);

    // Overview
    console.log(`${colors.bold}Overview:${colors.reset}`);
    console.log(`  Lua Files:        ${stats.lua.total}`);
    console.log(`  XML Files:        ${stats.xml.total} (${stats.xml.gui} GUI, ${stats.xml.translations} translations)`);
    console.log(`  Total Size:       ${formatFileSize(stats.lua.totalSize + stats.xml.totalSize)}`);
    console.log('');

    // Lines of code
    console.log(`${colors.bold}Lines of Code (Lua):${colors.reset}`);
    console.log(`  Total Lines:      ${stats.lua.totalLines.toLocaleString()}`);
    console.log(`  Code:             ${stats.lua.codeLines.toLocaleString()} (${Math.round(stats.lua.codeLines / stats.lua.totalLines * 100)}%)`);
    console.log(`  Comments:         ${stats.lua.commentLines.toLocaleString()} (${Math.round(stats.lua.commentLines / stats.lua.totalLines * 100)}%)`);
    console.log(`  Blank:            ${stats.lua.blankLines.toLocaleString()} (${Math.round(stats.lua.blankLines / stats.lua.totalLines * 100)}%)`);
    console.log('');

    // Component counts
    console.log(`${colors.bold}Components:${colors.reset}`);
    console.log(`  Dialogs:          ${stats.dialogs}`);
    console.log(`  Events:           ${stats.events}`);
    console.log(`  Managers:         ${stats.managers}`);
    console.log(`  Extensions:       ${stats.extensions}`);
    console.log('');

    // Files by category
    console.log(`${colors.bold}Files by Category:${colors.reset}`);
    const sortedCategories = Object.entries(stats.lua.byCategory)
        .filter(([_, data]) => data.files > 0)
        .sort((a, b) => b[1].lines - a[1].lines);

    for (const [category, data] of sortedCategories) {
        const pct = Math.round(data.lines / stats.lua.codeLines * 100);
        console.log(`  ${category.padEnd(22)} ${String(data.files).padStart(3)} files  ${String(data.lines.toLocaleString()).padStart(7)} lines (${pct}%)`);
    }
    console.log('');

    // Largest files
    console.log(`${colors.bold}Top 10 Largest Files:${colors.reset}`);
    for (let i = 0; i < stats.lua.largestFiles.length; i++) {
        const file = stats.lua.largestFiles[i];
        console.log(`  ${String(i + 1).padStart(2)}. ${file.name.padEnd(40)} ${String(file.lines).padStart(5)} lines  ${formatFileSize(file.size).padStart(8)}`);
    }
}

/**
 * Gather mod-specific information from modDesc.xml and code
 */
function gatherModInfo(modRoot) {
    const modInfo = {
        name: 'Unknown',
        version: 'Unknown',
        author: 'Unknown',
        title: 'Unknown',
        description: '',
        multiplayer: false,
        translations: [],
        inputActions: [],
        storeItems: [],
        specializations: {
            vehicle: [],
            placeable: []
        },
        vehicleTypes: [],
        placeableTypes: [],
        features: [],
        crossModCompat: [],
        settings: []
    };

    // Parse modDesc.xml
    const modDescPath = path.join(modRoot, 'modDesc.xml');
    if (fs.existsSync(modDescPath)) {
        const content = fs.readFileSync(modDescPath, 'utf8');

        // Basic info
        const versionMatch = content.match(/<version>([^<]+)<\/version>/);
        if (versionMatch) modInfo.version = versionMatch[1];

        const authorMatch = content.match(/<author>([^<]+)<\/author>/);
        if (authorMatch) modInfo.author = authorMatch[1];

        const titleMatch = content.match(/<title>\s*<en>([^<]+)<\/en>/);
        if (titleMatch) modInfo.title = titleMatch[1].replace(/&amp;/g, '&');

        // Multiplayer support
        modInfo.multiplayer = content.includes('multiplayer supported="true"');

        // Input actions
        const actionRegex = /<action name="([^"]+)"/g;
        let actionMatch;
        while ((actionMatch = actionRegex.exec(content)) !== null) {
            modInfo.inputActions.push(actionMatch[1]);
        }

        // Store items
        const storeRegex = /<storeItem xmlFilename="([^"]+)"/g;
        let storeMatch;
        while ((storeMatch = storeRegex.exec(content)) !== null) {
            modInfo.storeItems.push(storeMatch[1]);
        }

        // Vehicle specializations
        const vehSpecRegex = /<specializations>\s*([\s\S]*?)<\/specializations>/;
        const vehSpecBlock = content.match(vehSpecRegex);
        if (vehSpecBlock) {
            const specRegex = /<specialization name="([^"]+)"/g;
            let specMatch;
            while ((specMatch = specRegex.exec(vehSpecBlock[1])) !== null) {
                modInfo.specializations.vehicle.push(specMatch[1]);
            }
        }

        // Placeable specializations
        const placeSpecRegex = /<placeableSpecializations>\s*([\s\S]*?)<\/placeableSpecializations>/;
        const placeSpecBlock = content.match(placeSpecRegex);
        if (placeSpecBlock) {
            const specRegex = /<specialization name="([^"]+)"/g;
            let specMatch;
            while ((specMatch = specRegex.exec(placeSpecBlock[1])) !== null) {
                modInfo.specializations.placeable.push(specMatch[1]);
            }
        }

        // Vehicle types
        const vehTypeRegex = /<type name="([^"]+)"/g;
        let vehTypeMatch;
        while ((vehTypeMatch = vehTypeRegex.exec(content)) !== null) {
            if (!modInfo.vehicleTypes.includes(vehTypeMatch[1])) {
                modInfo.vehicleTypes.push(vehTypeMatch[1]);
            }
        }
    }

    // Count translations
    const transDir = path.join(modRoot, 'translations');
    if (fs.existsSync(transDir)) {
        const transFiles = fs.readdirSync(transDir).filter(f => f.endsWith('.xml'));
        for (const file of transFiles) {
            const langMatch = file.match(/translation_(\w+)\.xml/);
            if (langMatch) {
                modInfo.translations.push(langMatch[1].toUpperCase());
            }
        }
    }

    // Detect features from code patterns
    const featurePatterns = [
        { pattern: /FinanceManager|FinanceDeal/g, feature: 'Vehicle/Equipment Financing', icon: '💰' },
        { pattern: /LeaseDeal|LeaseVehicle/g, feature: 'Vehicle Leasing', icon: '📋' },
        { pattern: /LandLeaseDeal|LandLeaseEvent/g, feature: 'Land Leasing', icon: '🏞️' },
        { pattern: /CreditSystem|CreditScore/g, feature: 'Dynamic Credit Scoring (300-850)', icon: '📊' },
        { pattern: /TakeLoanDialog|TakeLoanEvent/g, feature: 'Collateral-Based Cash Loans', icon: '🏦' },
        { pattern: /UsedVehicleManager|UsedVehicleSearch/g, feature: 'Used Vehicle Marketplace', icon: '🚜' },
        { pattern: /VehicleSaleManager|VehicleSaleListing/g, feature: 'Agent-Based Vehicle Sales', icon: '🏷️' },
        { pattern: /NegotiationDialog|SellerResponseDialog/g, feature: 'Price Negotiation System', icon: '🤝' },
        { pattern: /InspectionReport|VehicleInspection/g, feature: 'Vehicle Inspection Reports', icon: '🔍' },
        { pattern: /RepairDialog|RepairVehicleEvent/g, feature: 'Partial Repair System (1-100%)', icon: '🔧' },
        { pattern: /TiresDialog|MaintenanceTires/g, feature: 'Tire Replacement System', icon: '⚙️' },
        { pattern: /FluidsDialog|MaintenanceFluids/g, feature: 'Fluid Service (Oil/Hydraulic)', icon: '🛢️' },
        { pattern: /FieldServiceKit/g, feature: 'Field Service Kit (Roadside Repairs)', icon: '🧰' },
        { pattern: /OBDScanner|DiagnosisData/g, feature: 'OBD Scanner Diagnostics', icon: '📟' },
        { pattern: /MaintenanceReliability|MaintenanceEngine/g, feature: 'Component Reliability System', icon: '⚡' },
        { pattern: /TradeInCalculations|tradeIn/gi, feature: 'Trade-In System', icon: '🔄' },
        { pattern: /DepreciationCalculations/g, feature: 'Realistic Depreciation', icon: '📉' },
        { pattern: /DifficultyScalingManager/g, feature: 'Difficulty-Based Pricing', icon: '⚖️' },
        { pattern: /BankInterestManager/g, feature: 'Bank Interest on Cash', icon: '💵' },
        { pattern: /PaymentTracker|PaymentHistory/g, feature: 'Payment History Tracking', icon: '📅' },
        { pattern: /RepossessionDialog/g, feature: 'Vehicle Repossession System', icon: '🚨' },
        { pattern: /FinanceManagerFrame/g, feature: 'ESC Menu Finance Manager', icon: '📱' },
        { pattern: /FinancialDashboard/g, feature: 'Financial Dashboard', icon: '📈' }
    ];

    // Detect cross-mod compatibility
    const crossModPatterns = [
        { pattern: /RVB|RealisticVehicleBreakdown/gi, mod: 'FS25_RealisticVehicleBreakdown (RVB)', icon: '🔗' },
        { pattern: /UYT|UsedYourTool/gi, mod: 'FS25_UsedYourTool (UYT)', icon: '🔗' },
        { pattern: /ModCompatibility/g, mod: 'Generic Mod Compatibility Layer', icon: '🔌' }
    ];

    // Scan source files for features
    const srcDir = path.join(modRoot, 'src');
    if (fs.existsSync(srcDir)) {
        const luaFiles = findFiles(srcDir, /\.lua$/);
        const allContent = luaFiles.map(f => {
            try { return fs.readFileSync(f, 'utf8'); }
            catch (e) { return ''; }
        }).join('\n');

        // Detect features
        for (const fp of featurePatterns) {
            if (fp.pattern.test(allContent)) {
                modInfo.features.push({ name: fp.feature, icon: fp.icon });
            }
            fp.pattern.lastIndex = 0; // Reset regex
        }

        // Detect cross-mod compatibility
        for (const cm of crossModPatterns) {
            if (cm.pattern.test(allContent)) {
                modInfo.crossModCompat.push({ name: cm.mod, icon: cm.icon });
            }
            cm.pattern.lastIndex = 0;
        }
    }

    // Count settings from UsedPlusSettings
    const settingsPath = path.join(modRoot, 'src', 'settings', 'UsedPlusSettings.lua');
    if (fs.existsSync(settingsPath)) {
        const settingsContent = fs.readFileSync(settingsPath, 'utf8');
        const settingRegex = /["'](\w+)["']\s*[=:]/g;
        const defaultsMatch = settingsContent.match(/DEFAULTS\s*=\s*\{([\s\S]*?)\}/);
        if (defaultsMatch) {
            let settingMatch;
            while ((settingMatch = settingRegex.exec(defaultsMatch[1])) !== null) {
                if (!['true', 'false', 'nil'].includes(settingMatch[1])) {
                    modInfo.settings.push(settingMatch[1]);
                }
            }
        }
    }

    // Scan for console commands
    modInfo.consoleCommands = [];
    const mainPath = path.join(modRoot, 'src', 'main.lua');
    if (fs.existsSync(mainPath)) {
        const mainContent = fs.readFileSync(mainPath, 'utf8');
        const cmdRegex = /addConsoleCommand\s*\(\s*"([^"]+)"\s*,\s*"([^"]+)"/g;
        let cmdMatch;
        while ((cmdMatch = cmdRegex.exec(mainContent)) !== null) {
            modInfo.consoleCommands.push({
                name: cmdMatch[1],
                description: cmdMatch[2]
            });
        }
    }

    // Scan for vehicle metrics tracked (maintenance system)
    modInfo.vehicleMetrics = [];
    modInfo.malfunctions = [];

    // Gather all maintenance-related content from main spec and modules
    let maintContent = '';
    const maintenancePath = path.join(modRoot, 'src', 'specializations', 'UsedPlusMaintenance.lua');
    if (fs.existsSync(maintenancePath)) {
        maintContent += fs.readFileSync(maintenancePath, 'utf8');
    }

    // Also scan maintenance modules
    const maintModulesDir = path.join(modRoot, 'src', 'specializations', 'maintenance');
    if (fs.existsSync(maintModulesDir)) {
        const moduleFiles = fs.readdirSync(maintModulesDir).filter(f => f.endsWith('.lua'));
        for (const file of moduleFiles) {
            try {
                maintContent += '\n' + fs.readFileSync(path.join(maintModulesDir, file), 'utf8');
            } catch (e) {}
        }
    }

    if (maintContent.length > 0) {

        // Detect tracked metrics
        const metricsPatterns = [
            { pattern: /spec\.oilLevel/g, metric: 'Engine Oil Level', icon: '🛢️', unit: '0-100%' },
            { pattern: /spec\.hydraulicFluidLevel/g, metric: 'Hydraulic Fluid Level', icon: '💧', unit: '0-100%' },
            { pattern: /spec\.tireQuality/g, metric: 'Tire Quality Grade', icon: '⚙️', unit: '1-3' },
            { pattern: /spec\.tireCondition/g, metric: 'Tire Condition', icon: '🔄', unit: '0-100%' },
            { pattern: /spec\.operatingHours/g, metric: 'Operating Hours', icon: '⏱️', unit: 'hours' },
            { pattern: /spec\.lastOilChange/g, metric: 'Last Oil Change', icon: '📅', unit: 'hours ago' },
            { pattern: /spec\.lastHydraulicService/g, metric: 'Last Hydraulic Service', icon: '🔧', unit: 'hours ago' },
            { pattern: /spec\.reliabilityScore/g, metric: 'Reliability Score', icon: '📊', unit: '0-100' },
            { pattern: /spec\.engineTemperature/g, metric: 'Engine Temperature', icon: '🌡️', unit: '°C' },
            { pattern: /spec\.engineHealth/g, metric: 'Engine Health', icon: '❤️', unit: '0-100%' },
            { pattern: /spec\.steeringPlay/g, metric: 'Steering Play', icon: '🎯', unit: '0-100%' },
            { pattern: /spec\.hasInspectionCache/g, metric: 'Inspection Cache', icon: '📋', unit: 'bool' },
            { pattern: /spec\.purchaseAge/g, metric: 'Purchase Age', icon: '📆', unit: 'hours' },
            { pattern: /spec\.oilServiceInterval/g, metric: 'Oil Service Interval', icon: '⏰', unit: 'hours' },
            { pattern: /spec\.hydraulicServiceInterval/g, metric: 'Hydraulic Service Interval', icon: '⏰', unit: 'hours' }
        ];

        for (const mp of metricsPatterns) {
            if (mp.pattern.test(maintContent)) {
                modInfo.vehicleMetrics.push({ name: mp.metric, icon: mp.icon, unit: mp.unit });
            }
            mp.pattern.lastIndex = 0;
        }

        // Detect malfunctions (based on actual spec variables in UsedPlusMaintenance)
        const malfunctionPatterns = [
            { pattern: /spec\.isStalled/g, malf: 'Engine Stall', icon: '🛑', desc: 'Engine stops unexpectedly' },
            { pattern: /spec\.isCutout/g, malf: 'Electrical Cutout', icon: '⚡', desc: 'Electrical system failure' },
            { pattern: /spec\.isOverheated/g, malf: 'Overheating', icon: '🔥', desc: 'Engine runs too hot' },
            { pattern: /spec\.isDrifting/g, malf: 'Steering Drift', icon: '↔️', desc: 'Vehicle pulls to one side' },
            { pattern: /spec\.hasFlatTire/g, malf: 'Flat Tire', icon: '🎈', desc: 'Tire puncture/blowout' },
            { pattern: /spec\.hasOilLeak/g, malf: 'Oil Leak', icon: '🛢️', desc: 'Losing engine oil' },
            { pattern: /spec\.hasHydraulicLeak/g, malf: 'Hydraulic Leak', icon: '💧', desc: 'Losing hydraulic fluid' },
            { pattern: /spec\.hasFuelLeak/g, malf: 'Fuel Leak', icon: '⛽', desc: 'Losing fuel' },
            { pattern: /spec\.engineSeized/g, malf: 'Engine Seizure', icon: '💀', desc: 'Permanent engine damage' }
        ];

        for (const mf of malfunctionPatterns) {
            if (mf.pattern.test(maintContent)) {
                modInfo.malfunctions.push({ name: mf.malf, icon: mf.icon, description: mf.desc });
            }
            mf.pattern.lastIndex = 0;
        }
    }

    // Get maintenance module names
    const maintModulesDirForNames = path.join(modRoot, 'src', 'specializations', 'maintenance');
    if (fs.existsSync(maintModulesDirForNames)) {
        modInfo.maintenanceModules = fs.readdirSync(maintModulesDirForNames)
            .filter(f => f.endsWith('.lua'))
            .map(f => f.replace('.lua', '').replace('Maintenance', ''));
    } else {
        modInfo.maintenanceModules = [];
    }

    // Scan for vanilla hooks (Utils.appendedFunction / prependedFunction)
    modInfo.vanillaHooks = [];
    modInfo.eventSubscriptions = [];

    const srcDirForHooks = path.join(modRoot, 'src');
    if (fs.existsSync(srcDirForHooks)) {
        const luaFilesForHooks = findFiles(srcDirForHooks, /\.lua$/);

        for (const file of luaFilesForHooks) {
            try {
                const content = fs.readFileSync(file, 'utf8');
                const relPath = path.relative(modRoot, file).replace(/\\/g, '/');
                const fileName = path.basename(file, '.lua');

                // Find Utils.appendedFunction hooks
                const appendRegex = /(\w+(?:\.\w+)*)\s*=\s*Utils\.appendedFunction\s*\(\s*(\w+(?:\.\w+)*)/g;
                let match;
                while ((match = appendRegex.exec(content)) !== null) {
                    const target = match[2];
                    // Skip if target matches the first part (self-reference)
                    if (!target.startsWith(fileName)) {
                        modInfo.vanillaHooks.push({
                            type: 'append',
                            target: target,
                            source: relPath
                        });
                    }
                }

                // Find Utils.prependedFunction hooks
                const prependRegex = /(\w+(?:\.\w+)*)\s*=\s*Utils\.prependedFunction\s*\(\s*(\w+(?:\.\w+)*)/g;
                while ((match = prependRegex.exec(content)) !== null) {
                    const target = match[2];
                    if (!target.startsWith(fileName)) {
                        modInfo.vanillaHooks.push({
                            type: 'prepend',
                            target: target,
                            source: relPath
                        });
                    }
                }

                // Find g_messageCenter:subscribe
                const subscribeRegex = /g_messageCenter:subscribe\s*\(\s*MessageType\.(\w+)/g;
                while ((match = subscribeRegex.exec(content)) !== null) {
                    const existing = modInfo.eventSubscriptions.find(e => e.event === match[1] && e.source === relPath);
                    if (!existing) {
                        modInfo.eventSubscriptions.push({
                            event: match[1],
                            source: relPath
                        });
                    }
                }
            } catch (e) {}
        }

        // Remove duplicates from hooks (same target might be hooked in multiple places)
        const uniqueHooks = [];
        const seenHooks = new Set();
        for (const hook of modInfo.vanillaHooks) {
            const key = `${hook.type}:${hook.target}`;
            if (!seenHooks.has(key)) {
                seenHooks.add(key);
                uniqueHooks.push(hook);
            }
        }
        modInfo.vanillaHooks = uniqueHooks;
    }

    return modInfo;
}

/**
 * Print mod-specific information
 */
function printModInfo(modInfo, stats) {
    console.log(`\n${colors.bold}${colors.cyan}=== Mod Information ===${colors.reset}\n`);

    // Header
    console.log(`${colors.bold}${modInfo.title}${colors.reset}`);
    console.log(`  Version:          ${modInfo.version}`);
    console.log(`  Author:           ${modInfo.author}`);
    console.log(`  Multiplayer:      ${modInfo.multiplayer ? colors.green + 'Supported' + colors.reset : colors.red + 'No' + colors.reset}`);
    console.log('');

    // Features
    console.log(`${colors.bold}Features Implemented (${modInfo.features.length}):${colors.reset}`);
    const featureCols = 2;
    const featureRows = Math.ceil(modInfo.features.length / featureCols);
    for (let row = 0; row < featureRows; row++) {
        let line = '';
        for (let col = 0; col < featureCols; col++) {
            const idx = row + col * featureRows;
            if (idx < modInfo.features.length) {
                const f = modInfo.features[idx];
                line += `  ${f.icon} ${f.name.padEnd(35)}`;
            }
        }
        console.log(line);
    }
    console.log('');

    // Cross-mod compatibility
    if (modInfo.crossModCompat.length > 0) {
        console.log(`${colors.bold}Cross-Mod Compatibility (${modInfo.crossModCompat.length}):${colors.reset}`);
        for (const cm of modInfo.crossModCompat) {
            console.log(`  ${cm.icon} ${cm.name}`);
        }
        console.log('');
    }

    // Translations
    console.log(`${colors.bold}Language Support (${modInfo.translations.length}):${colors.reset}`);
    console.log(`  ${modInfo.translations.join(', ')}`);
    console.log('');

    // Input bindings
    if (modInfo.inputActions.length > 0) {
        console.log(`${colors.bold}Keyboard Shortcuts (${modInfo.inputActions.length}):${colors.reset}`);
        for (const action of modInfo.inputActions) {
            // Clean up action name for display
            const displayName = action.replace('USEDPLUS_', '').replace(/_/g, ' ');
            console.log(`  ⌨️  ${displayName}`);
        }
        console.log('');
    }

    // Store items
    if (modInfo.storeItems.length > 0) {
        console.log(`${colors.bold}Store Items (${modInfo.storeItems.length}):${colors.reset}`);
        for (const item of modInfo.storeItems) {
            const itemName = path.basename(item, '.xml');
            console.log(`  🛒 ${itemName}`);
        }
        console.log('');
    }

    // Specializations
    const totalSpecs = modInfo.specializations.vehicle.length + modInfo.specializations.placeable.length;
    if (totalSpecs > 0) {
        console.log(`${colors.bold}Custom Specializations (${totalSpecs}):${colors.reset}`);
        for (const spec of modInfo.specializations.vehicle) {
            console.log(`  🚜 ${spec} (Vehicle)`);
        }
        for (const spec of modInfo.specializations.placeable) {
            console.log(`  🏭 ${spec} (Placeable)`);
        }
        console.log('');
    }

    // Settings count
    if (modInfo.settings.length > 0) {
        console.log(`${colors.bold}Configurable Settings:${colors.reset} ${modInfo.settings.length} options`);
        console.log('');
    }

    // Console commands
    if (modInfo.consoleCommands && modInfo.consoleCommands.length > 0) {
        console.log(`${colors.bold}Console Commands (${modInfo.consoleCommands.length}):${colors.reset}`);
        for (const cmd of modInfo.consoleCommands) {
            console.log(`  💻 ${colors.cyan}${cmd.name}${colors.reset}`);
            console.log(`      ${cmd.description}`);
        }
        console.log('');
    }

    // Vanilla hooks
    if (modInfo.vanillaHooks && modInfo.vanillaHooks.length > 0) {
        console.log(`${colors.bold}${colors.red}=== Vanilla Game Hooks ===${colors.reset}\n`);

        // Group by class
        const hooksByClass = {};
        for (const hook of modInfo.vanillaHooks) {
            const parts = hook.target.split('.');
            const className = parts[0];
            if (!hooksByClass[className]) {
                hooksByClass[className] = [];
            }
            hooksByClass[className].push(hook);
        }

        console.log(`${colors.bold}Hooked Functions (${modInfo.vanillaHooks.length}):${colors.reset}`);
        for (const [className, hooks] of Object.entries(hooksByClass).sort()) {
            console.log(`  ${colors.yellow}${className}${colors.reset}`);
            for (const hook of hooks) {
                const funcName = hook.target.split('.').slice(1).join('.');
                const hookType = hook.type === 'prepend' ? '⬆️ PRE' : '⬇️ POST';
                console.log(`    ${hookType}  ${funcName}`);
            }
        }
        console.log('');

        // Event subscriptions
        if (modInfo.eventSubscriptions && modInfo.eventSubscriptions.length > 0) {
            console.log(`${colors.bold}Event Subscriptions (${modInfo.eventSubscriptions.length}):${colors.reset}`);
            const eventGroups = {};
            for (const sub of modInfo.eventSubscriptions) {
                if (!eventGroups[sub.event]) {
                    eventGroups[sub.event] = [];
                }
                const shortSource = sub.source.split('/').pop();
                if (!eventGroups[sub.event].includes(shortSource)) {
                    eventGroups[sub.event].push(shortSource);
                }
            }
            for (const [event, sources] of Object.entries(eventGroups).sort()) {
                console.log(`  📡 MessageType.${event}`);
                console.log(`      → ${sources.join(', ')}`);
            }
            console.log('');
        }
    }

    // Vehicle Maintenance System
    if ((modInfo.vehicleMetrics && modInfo.vehicleMetrics.length > 0) ||
        (modInfo.malfunctions && modInfo.malfunctions.length > 0)) {
        console.log(`${colors.bold}${colors.yellow}=== Vehicle Maintenance System ===${colors.reset}\n`);

        // Maintenance modules
        if (modInfo.maintenanceModules && modInfo.maintenanceModules.length > 0) {
            console.log(`${colors.bold}Maintenance Modules (${modInfo.maintenanceModules.length}):${colors.reset}`);
            console.log(`  ${modInfo.maintenanceModules.join(', ')}`);
            console.log('');
        }

        // Vehicle metrics
        if (modInfo.vehicleMetrics && modInfo.vehicleMetrics.length > 0) {
            console.log(`${colors.bold}Vehicle Metrics Tracked (${modInfo.vehicleMetrics.length}):${colors.reset}`);
            for (const m of modInfo.vehicleMetrics) {
                console.log(`  ${m.icon} ${m.name.padEnd(28)} (${m.unit})`);
            }
            console.log('');
        }

        // Malfunctions
        if (modInfo.malfunctions && modInfo.malfunctions.length > 0) {
            console.log(`${colors.bold}Malfunction Events (${modInfo.malfunctions.length}):${colors.reset}`);
            for (const mf of modInfo.malfunctions) {
                console.log(`  ${mf.icon} ${mf.name.padEnd(20)} - ${mf.description}`);
            }
            console.log('');
        }
    }

    // Quick stats summary
    console.log(`${colors.bold}Quick Stats:${colors.reset}`);
    console.log(`  📁 ${stats.lua.total} Lua files | ${stats.xml.total} XML files`);
    console.log(`  📝 ${stats.lua.codeLines.toLocaleString()} lines of code | ${stats.lua.commentLines.toLocaleString()} comments`);
    console.log(`  🖥️  ${stats.dialogs} dialogs | ${stats.events} event types | ${stats.managers} managers`);
    console.log(`  💾 ${formatFileSize(stats.lua.totalSize + stats.xml.totalSize)} total size`);
}

/**
 * Main function
 */
function main() {
    const args = process.argv.slice(2);
    const verbose = args.includes('--verbose') || args.includes('-v');
    const checkFunctions = args.includes('--check-functions') || args.includes('-f');

    console.log(`\n${colors.bold}${colors.cyan}=== FS25_UsedPlus Unused Code Scanner ===${colors.reset}\n`);

    const modRoot = getModRoot();
    console.log(`Mod root: ${modRoot}\n`);

    let issuesFound = 0;

    // === Check 1: Unregistered Lua files ===
    console.log(`${colors.bold}[1] Checking for unregistered Lua files...${colors.reset}`);
    const registered = parseModDescSources(modRoot);
    const allLua = findAllLuaFiles(modRoot);

    const unregistered = [...allLua].filter(f => !registered.has(f));
    if (unregistered.length > 0) {
        console.log(`${colors.yellow}  Found ${unregistered.length} unregistered file(s):${colors.reset}`);
        for (const f of unregistered.sort()) {
            console.log(`    - ${f}`);
            issuesFound++;
        }
    } else {
        console.log(`${colors.green}  All Lua files are registered in modDesc.xml${colors.reset}`);
    }

    // === Check 2: Orphaned dialogs ===
    console.log(`\n${colors.bold}[2] Checking for orphaned dialogs...${colors.reset}`);
    const dialogs = findAllDialogs(modRoot);
    const orphanedDialogs = [];

    for (const [dialogName, files] of Object.entries(dialogs)) {
        const refs = searchDialogReferences(modRoot, dialogName);
        if (refs.length === 0) {
            orphanedDialogs.push({ name: dialogName, ...files });
        }
    }

    if (orphanedDialogs.length > 0) {
        console.log(`${colors.yellow}  Found ${orphanedDialogs.length} potentially orphaned dialog(s):${colors.reset}`);
        for (const dialog of orphanedDialogs) {
            console.log(`    - ${dialog.name}`);
            if (dialog.lua) console.log(`        Lua: ${path.relative(modRoot, dialog.lua)}`);
            if (dialog.xml) console.log(`        XML: ${path.relative(modRoot, dialog.xml)}`);
            issuesFound++;
        }
    } else {
        console.log(`${colors.green}  All dialogs appear to be in use${colors.reset}`);
    }

    // === Check 3: Mismatched dialog pairs ===
    console.log(`\n${colors.bold}[3] Checking for mismatched dialog pairs...${colors.reset}`);
    const mismatched = [];

    for (const [dialogName, files] of Object.entries(dialogs)) {
        if (files.lua && !files.xml) {
            mismatched.push({ name: dialogName, issue: 'Missing XML' });
        } else if (files.xml && !files.lua) {
            mismatched.push({ name: dialogName, issue: 'Missing Lua' });
        }
    }

    if (mismatched.length > 0) {
        console.log(`${colors.yellow}  Found ${mismatched.length} mismatched pair(s):${colors.reset}`);
        for (const item of mismatched) {
            console.log(`    - ${item.name}: ${item.issue}`);
            issuesFound++;
        }
    } else {
        console.log(`${colors.green}  All dialogs have matching Lua/XML pairs${colors.reset}`);
    }

    // === Summary ===
    console.log(`\n${colors.bold}${'='.repeat(50)}${colors.reset}`);
    if (issuesFound > 0) {
        console.log(`${colors.yellow}Found ${issuesFound} potential issue(s) to review${colors.reset}`);
    } else {
        console.log(`${colors.green}No issues found!${colors.reset}`);
    }

    // === Mod Info & Statistics ===
    const stats = gatherStatistics(modRoot);
    const modInfo = gatherModInfo(modRoot);
    printModInfo(modInfo, stats);
    printStatistics(stats);

    console.log(`\n${colors.cyan}Options:${colors.reset}`);
    console.log('  --verbose, -v          Show more details');
    console.log('  --check-functions, -f  Check for unused functions (not yet implemented)');

    return issuesFound;
}

// Run
process.exit(main());
