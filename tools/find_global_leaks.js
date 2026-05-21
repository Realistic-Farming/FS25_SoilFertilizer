const fs = require('fs');
const path = require('path');

const srcDir = path.join(__dirname, '..', 'src');
const outputFile = path.join(__dirname, '..', 'GLOBAL_LEAK_AUDIT.md');

const issues = [];
let totalFiles = 0;

function isClassDefinition(line) {
    // Top-level class definitions like "MyClass = {}"
    return /^[A-Z][a-zA-Z0-9_]*\s*=\s*\{/.test(line);
}

function isValidGlobal(line) {
    // Valid patterns that are intentional globals
    return (
        /^[A-Z][a-zA-Z0-9_]*\s*=\s*\{/.test(line) ||  // Class definition
        /^g_[a-zA-Z]/.test(line) ||                    // g_ prefix (intentional global)
        /^source\(/.test(line) ||                      // source() calls
        line.includes('self.') ||                       // self references
        line.includes('spec.') ||                       // spec references
        line.includes('this.') ||                       // this references
        /^\s*--/.test(line) ||                         // Comments
        /^\s*local\s/.test(line) ||                    // local keyword
        /^\s*\[["'][a-zA-Z_]/.test(line) ||           // Table key assignment
        /^\s*[A-Z_]+\s*=/.test(line.trim()) &&         // CONSTANT = value (in table def)
          line.trim().endsWith(',')
    );
}

function analyzeLine(line, lineNum, filePath) {
    const trimmed = line.trim();

    // Skip empty lines, comments, and lines starting with keywords
    if (!trimmed || trimmed.startsWith('--') || trimmed.startsWith('local ')) {
        return null;
    }

    // Look for assignment without local
    const match = trimmed.match(/^([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*([^=].*)/);
    if (match && line.startsWith('    ')) {  // Indented = inside a function
        const varName = match[1];
        const value = match[2];

        // Filter out valid patterns
        if (varName === 'self' || varName === 'spec' || varName === 'this') return null;
        if (varName.startsWith('g_')) return null;
        if (isValidGlobal(line)) return null;

        // Check if it's a table field (has dots before)
        if (line.includes('.') && line.indexOf('.') < line.indexOf('=')) return null;

        // Potential leak!
        return {
            file: filePath,
            line: lineNum,
            variable: varName,
            value: value.substring(0, 50),  // Truncate long values
            code: line
        };
    }

    return null;
}

function analyzeFile(filePath) {
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');
    const fileIssues = [];

    lines.forEach((line, idx) => {
        const issue = analyzeLine(line, idx + 1, filePath);
        if (issue) {
            fileIssues.push(issue);
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
    if (['i', 'j', 'k', 'count', 'index', 'total', 'sum'].includes(varName)) {
        return 'HIGH';
    }

    // High: variables used in calculations
    if (['score', 'result', 'value', 'amount', 'price', 'cost'].includes(varName)) {
        return 'HIGH';
    }

    // Medium: descriptive names that might be temps
    if (varName.endsWith('Score') || varName.endsWith('Bonus') ||
        varName.endsWith('Penalty') || varName.endsWith('Total')) {
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
                section += `**Line ${issue.line}:** \`${issue.variable}\`\n`;
                section += `\`\`\`lua\n${issue.code.trim()}\n\`\`\`\n`;
                section += `**Recommendation:** Add \`local\` keyword before \`${issue.variable}\`\n\n`;
            });

            section += `---\n\n`;
        });

        return section;
    }

    report += writeSection('HIGH SEVERITY', high);
    report += writeSection('MEDIUM SEVERITY', medium);
    report += writeSection('LOW SEVERITY', low);

    report += `## Summary & Recommendations\n\n`;
    report += `### Pattern Analysis\n\n`;

    const varCounts = {};
    issues.forEach(i => {
        varCounts[i.variable] = (varCounts[i.variable] || 0) + 1;
    });

    const sorted = Object.entries(varCounts).sort((a, b) => b[1] - a[1]);
    report += `**Most common leaked variable names:**\n\n`;
    sorted.slice(0, 10).forEach(([name, count]) => {
        report += `- \`${name}\`: ${count} occurrences\n`;
    });

    report += `\n### General Recommendations\n\n`;
    report += `1. **Add \`local\` keyword** to all variable assignments inside functions\n`;
    report += `2. **For loop counters** like \`i\`, \`j\`, \`count\`: Always use \`local for i = 1, n do\`\n`;
    report += `3. **For calculations**: Declare temps as \`local score = 0\` at function start\n`;
    report += `4. **Review HIGH severity** items first - these are most likely to cause bugs\n`;
    report += `5. **Test thoroughly** after fixes - global leaks can have subtle cross-module effects\n\n`;

    report += `### Known Safe Patterns (Excluded)\n\n`;
    report += `- Class definitions: \`MyClass = {}\` at top level\n`;
    report += `- Intentional globals: \`g_myGlobal = ...\`\n`;
    report += `- Self/spec references: \`self.field = ...\`, \`spec.field = ...\`\n`;
    report += `- Table field assignments: \`myTable.field = ...\`\n`;
    report += `- Constants in table definitions: \`CONSTANT_NAME = value,\`\n\n`;

    return report;
}

// Run the scan
console.log('Scanning for global variable leaks...');
scanDirectory(srcDir);

const report = generateReport();
fs.writeFileSync(outputFile, report);

console.log(`\nAudit complete!`);
console.log(`- Files scanned: ${totalFiles}`);
console.log(`- Potential leaks: ${issues.length}`);
console.log(`- Report written to: ${outputFile}`);
