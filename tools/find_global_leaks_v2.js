const fs = require('fs');
const path = require('path');

const srcDir = path.join(__dirname, '..', 'src');
const outputFile = path.join(__dirname, '..', 'GLOBAL_LEAK_AUDIT.md');

const issues = [];
let totalFiles = 0;

function analyzeFile(filePath) {
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');
    const fileIssues = [];

    // Track local variables per function scope
    let inFunction = false;
    let functionDepth = 0;
    let localVars = new Set();
    let linesBefore = [];

    lines.forEach((line, idx) => {
        const trimmed = line.trim();
        const lineNum = idx + 1;

        // Track function scope
        if (/^function\s/.test(trimmed) || /\sfunction\s*\(/.test(trimmed)) {
            inFunction = true;
            functionDepth = 0;
            localVars = new Set();
        }

        // Track 'end' keywords (rough depth tracking)
        const endMatches = line.match(/\bend\b/g);
        if (endMatches) {
            functionDepth -= endMatches.length;
            if (functionDepth <= 0) {
                inFunction = false;
                localVars.clear();
            }
        }

        // Track 'do', 'then', 'repeat' keywords (increase depth)
        if (/\b(do|then|repeat)\b/.test(line)) {
            functionDepth++;
        }

        // Collect local variable declarations
        const localMatch = trimmed.match(/^local\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
        if (localMatch) {
            localVars.add(localMatch[1]);
        }

        // Look for assignments without 'local' inside functions
        if (inFunction && line.startsWith('    ')) {  // Indented
            // Skip comments
            if (trimmed.startsWith('--')) {
                linesBefore.push(line);
                return;
            }

            // Match variable assignment (not table field, not self/spec)
            const match = trimmed.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*([^=].*)/);
            if (match) {
                const varName = match[1];
                const value = match[2];

                // Filter out safe patterns
                if (varName === 'self' || varName === 'spec' || varName === 'this') {
                    linesBefore.push(line);
                    return;
                }
                if (varName.startsWith('g_')) {
                    linesBefore.push(line);
                    return;
                }
                if (localVars.has(varName)) {
                    // This is modifying a local variable (safe!)
                    linesBefore.push(line);
                    return;
                }
                if (line.includes('.') && line.indexOf('.') < line.indexOf('=')) {
                    // Table field assignment like foo.bar = ...
                    linesBefore.push(line);
                    return;
                }
                if (trimmed.endsWith(',') || trimmed.endsWith('},')) {
                    // Part of table initialization
                    linesBefore.push(line);
                    return;
                }

                // POTENTIAL LEAK!
                const context = [
                    ...linesBefore.slice(-2),
                    line,
                    ...lines.slice(idx + 1, idx + 3)
                ].join('\n');

                fileIssues.push({
                    file: filePath,
                    line: lineNum,
                    variable: varName,
                    value: value.substring(0, 50),
                    code: line.trim(),
                    context: context
                });
            }
        }

        // Keep last 3 lines for context
        linesBefore.push(line);
        if (linesBefore.length > 3) {
            linesBefore.shift();
        }
    });

    return fileIssues;
}

function scanDirectory(dir) {
    const entries = fs.readdirSync(dir, { withFileTypes: true });

    for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isDirectory()) {
            scanDirectory(fullPath);
        } else if (entry.isFile() && entry.name.endsWith('.lua')) {
            totalFiles++;
            const fileIssues = analyzeFile(fullPath);
            issues.push(...fileIssues);
        }
    }
}

function categorizeIssue(issue) {
    const varName = issue.variable;

    // High severity: loop counters, common temp vars
    if (['i', 'j', 'k', 'count', 'index', 'total', 'sum', 'result'].includes(varName)) {
        return 'HIGH';
    }

    // High: variables used in calculations
    if (['score', 'value', 'amount', 'price', 'cost', 'balance'].includes(varName)) {
        return 'HIGH';
    }

    // Medium: descriptive names that might be temps
    if (varName.endsWith('Score') || varName.endsWith('Bonus') ||
        varName.endsWith('Penalty') || varName.endsWith('Total') ||
        varName.endsWith('Index') || varName.endsWith('Count')) {
        return 'MEDIUM';
    }

    // Low: everything else
    return 'LOW';
}

function generateReport() {
    const high = issues.filter(i => categorizeIssue(i) === 'HIGH');
    const medium = issues.filter(i => categorizeIssue(i) === 'MEDIUM');
    const low = issues.filter(i => categorizeIssue(i) === 'LOW');

    let report = `# GLOBAL VARIABLE LEAK AUDIT - FS25_UsedPlus\n\n`;
    report += `**Generated:** ${new Date().toISOString()}\n`;
    report += `**Total Lua files scanned:** ${totalFiles}\n`;
    report += `**Potential leaks found:** ${issues.length}\n\n`;
    report += `## Severity Breakdown\n\n`;
    report += `- **HIGH:** ${high.length} (immediate fix recommended)\n`;
    report += `- **MEDIUM:** ${medium.length} (review needed)\n`;
    report += `- **LOW:** ${low.length} (low priority)\n\n`;
    report += `---\n\n`;

    function writeSection(title, items) {
        if (items.length === 0) return '';

        let section = `## ${title}\n\n`;

        // Group by file
        const byFile = {};
        items.forEach(issue => {
            const relPath = issue.file.replace(/\\/g, '/').split('/src/')[1];
            if (!byFile[relPath]) byFile[relPath] = [];
            byFile[relPath].push(issue);
        });

        Object.keys(byFile).sort().forEach(file => {
            section += `### \`src/${file}\`\n\n`;

            byFile[file].forEach(issue => {
                section += `**Line ${issue.line}:** \`${issue.variable} = ${issue.value}\`\n\n`;
                section += `\`\`\`lua\n${issue.context}\n\`\`\`\n\n`;
                section += `**Issue:** Variable \`${issue.variable}\` is assigned without \`local\` keyword.\n`;
                section += `**Fix:** Add \`local ${issue.variable}\` before first use, or add \`local\` to this line.\n\n`;
                section += `---\n\n`;
            });
        });

        return section;
    }

    report += writeSection('HIGH SEVERITY LEAKS', high);
    report += writeSection('MEDIUM SEVERITY LEAKS', medium);
    report += writeSection('LOW SEVERITY LEAKS', low);

    report += `## Summary & Recommendations\n\n`;
    report += `### Pattern Analysis\n\n`;

    const varCounts = {};
    issues.forEach(i => {
        varCounts[i.variable] = (varCounts[i.variable] || 0) + 1;
    });

    const sorted = Object.entries(varCounts).sort((a, b) => b[1] - a[1]);
    report += `**Most common leaked variable names:**\n\n`;
    sorted.slice(0, 15).forEach(([name, count]) => {
        report += `- \`${name}\`: ${count} occurrences\n`;
    });

    report += `\n### General Recommendations\n\n`;
    report += `1. **Add \`local\` keyword** to all variable declarations\n`;
    report += `2. **For loop counters**: Use \`for i = 1, n do\` (implicit local) or \`local i; for i = ...\`\n`;
    report += `3. **For calculations**: Declare temps as \`local score = 0\` at function start\n`;
    report += `4. **Review HIGH severity** items first - these are most likely to cause bugs\n`;
    report += `5. **Test thoroughly** after fixes - global leaks can have subtle effects\n\n`;

    report += `### Impact of Global Leaks\n\n`;
    report += `Global variables in Lua can cause:\n`;
    report += `- **Cross-contamination**: Variable values leak between function calls\n`;
    report += `- **Multiplayer bugs**: Server/client state corruption\n`;
    report += `- **Hard-to-debug issues**: Values mysteriously changing\n`;
    report += `- **Performance**: Global table lookups are slower than locals\n\n`;

    report += `### Known Safe Patterns (Excluded from Report)\n\n`;
    report += `- Class definitions: \`MyClass = {}\` at top level\n`;
    report += `- Intentional globals: \`g_myGlobal = ...\`\n`;
    report += `- Self/spec references: \`self.field = ...\`, \`spec.field = ...\`\n`;
    report += `- Table field assignments: \`myTable.field = ...\`\n`;
    report += `- Local variable modifications: \`score = score + 10\` (if \`local score\` was declared earlier)\n`;
    report += `- Table initializations: Lines ending with \`,\` or \`},\`\n\n`;

    return report;
}

// Run the scan
console.log('Scanning for global variable leaks (v2 - scope-aware)...');
scanDirectory(srcDir);

const report = generateReport();
fs.writeFileSync(outputFile, report);

console.log(`\nAudit complete!`);
console.log(`- Files scanned: ${totalFiles}`);
console.log(`- Potential leaks: ${issues.length}`);
console.log(`- Report written to: ${outputFile}`);
