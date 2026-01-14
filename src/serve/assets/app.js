// Ligi Markdown Viewer Application

(function() {
    'use strict';

    // State
    let currentFile = null;
    let fileList = [];

    // DOM elements
    const fileListEl = document.getElementById('file-list');
    const contentEl = document.getElementById('content');

    // Utility: escape HTML (defined early for use in marked extension)
    function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // Configure marked for GFM with mermaid extension
    marked.use({
        gfm: true,
        breaks: true,
        extensions: [{
            name: 'mermaid',
            level: 'block',
            start(src) {
                return src.match(/^```mermaid/m)?.index;
            },
            tokenizer(src) {
                const match = src.match(/^```mermaid\s*\n([\s\S]*?)```/);
                if (match) {
                    return {
                        type: 'mermaid',
                        raw: match[0],
                        text: match[1].trim()
                    };
                }
            },
            renderer(token) {
                return '<div class="mermaid">' + escapeHtml(token.text) + '</div>';
            }
        }]
    });

    const languageAliases = {
        'c++': 'cpp',
        'cpp': 'cpp',
        'c': 'c',
        'go': 'go',
        'zig': 'zig',
        'rust': 'rust',
        'solidity': 'solidity',
        'assembly': 'x86asm',
        'asm': 'x86asm',
        'bash': 'bash',
        'sh': 'bash',
        'shell': 'bash',
        'zsh': 'bash',
        'python': 'python',
        'py': 'python',
        'javascript': 'javascript',
        'js': 'javascript',
        'css': 'css',
        'html': 'xml',
        'htlm': 'xml',
        'xml': 'xml',
        'markdown': 'markdown',
        'md': 'markdown',
        'text': 'plaintext',
        'plain': 'plaintext'
    };

    const highlightAutoLanguages = [];

    function normalizeLanguage(language) {
        if (!language) return null;
        const key = language.toLowerCase();
        return languageAliases[key] || key;
    }

    function getLanguageFromClass(codeEl) {
        for (const cls of codeEl.classList) {
            if (cls.startsWith('language-')) {
                return cls.slice('language-'.length);
            }
        }
        return null;
    }

    function getHighlightAutoLanguages() {
        if (!window.hljs) return [];
        if (highlightAutoLanguages.length > 0) return highlightAutoLanguages;

        const seen = new Set();
        Object.values(languageAliases).forEach(lang => {
            if (hljs.getLanguage(lang) && !seen.has(lang)) {
                seen.add(lang);
                highlightAutoLanguages.push(lang);
            }
        });

        return highlightAutoLanguages;
    }

    function highlightCodeBlocks() {
        if (!window.hljs) return;

        const autoLanguages = getHighlightAutoLanguages();
        const codeBlocks = contentEl.querySelectorAll('pre code');

        codeBlocks.forEach(codeEl => {
            const rawLanguage = getLanguageFromClass(codeEl);
            const normalized = normalizeLanguage(rawLanguage);

            if (normalized && hljs.getLanguage(normalized)) {
                codeEl.classList.add('hljs');
                codeEl.innerHTML = hljs.highlight(codeEl.textContent, {
                    language: normalized,
                    ignoreIllegals: true
                }).value;
                return;
            }

            const result = autoLanguages.length > 0
                ? hljs.highlightAuto(codeEl.textContent, autoLanguages)
                : hljs.highlightAuto(codeEl.textContent);
            codeEl.classList.add('hljs');
            codeEl.innerHTML = result.value;
        });
    }

    // Initialize mermaid
    mermaid.initialize({
        startOnLoad: false,
        theme: 'dark',
        securityLevel: 'loose',
        fontFamily: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace'
    });

    const imageExtensions = new Set([
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.svg',
        '.webp'
    ]);

    function safeDecode(value) {
        try {
            return decodeURIComponent(value);
        } catch (err) {
            return value;
        }
    }

    function isExternalHref(href) {
        return /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(href);
    }

    function splitHref(href) {
        let path = href;
        let hash = '';
        let query = '';

        const hashIndex = path.indexOf('#');
        if (hashIndex !== -1) {
            hash = path.slice(hashIndex + 1);
            path = path.slice(0, hashIndex);
        }

        const queryIndex = path.indexOf('?');
        if (queryIndex !== -1) {
            query = path.slice(queryIndex + 1);
            path = path.slice(0, queryIndex);
        }

        return { path, query, hash };
    }

    function normalizePath(rawPath) {
        const segments = rawPath.split('/');
        const stack = [];

        for (const segment of segments) {
            if (!segment || segment === '.') {
                continue;
            }
            if (segment === '..') {
                if (stack.length === 0) {
                    return null;
                }
                stack.pop();
                continue;
            }
            stack.push(segment);
        }

        return stack.join('/');
    }

    function resolveRelativePath(basePath, hrefPath) {
        if (!hrefPath) return null;

        const decoded = safeDecode(hrefPath).replace(/\\/g, '/');
        if (decoded.startsWith('/')) {
            return normalizePath(decoded.slice(1));
        }

        const baseDir = basePath ? basePath.slice(0, basePath.lastIndexOf('/') + 1) : '';
        return normalizePath(baseDir + decoded);
    }

    function resolveMarkdownPath(path) {
        if (!path) return null;

        if (fileList.includes(path)) return path;

        if (!path.endsWith('.md') && !path.endsWith('.markdown')) {
            if (fileList.includes(path + '.md')) return path + '.md';
            if (fileList.includes(path + '.markdown')) return path + '.markdown';
        }

        return null;
    }

    function isImagePath(path) {
        if (!path) return false;
        const dotIndex = path.lastIndexOf('.');
        if (dotIndex === -1) return false;
        return imageExtensions.has(path.slice(dotIndex).toLowerCase());
    }

    function buildHash(path, anchor) {
        const combined = anchor ? path + '#' + anchor : path;
        return '#' + encodeURIComponent(combined);
    }

    function updateHash(path, anchor) {
        const hash = buildHash(path, anchor);
        if (window.location.hash !== hash) {
            window.location.hash = hash;
        }
    }

    function scrollToAnchor(anchor) {
        if (!anchor) return;
        const id = safeDecode(anchor);
        const target = document.getElementById(id);
        if (target) {
            target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }

    function rewriteContentLinks() {
        const links = contentEl.querySelectorAll('a[href]');
        links.forEach(link => {
            const href = link.getAttribute('href');
            if (!href || href.startsWith('#')) return;
            if (isExternalHref(href)) return;
            if (href.startsWith('/assets/') || href.startsWith('/api/')) return;

            const parts = splitHref(href);
            const resolvedPath = resolveRelativePath(currentFile, parts.path);
            if (!resolvedPath) return;

            const markdownPath = resolveMarkdownPath(resolvedPath);
            if (markdownPath) {
                link.setAttribute('href', buildHash(markdownPath, parts.hash));
                link.dataset.ligiPath = markdownPath;
                if (parts.hash) {
                    link.dataset.ligiAnchor = parts.hash;
                }
                return;
            }

            if (isImagePath(resolvedPath)) {
                link.setAttribute('href', '/api/file?path=' + encodeURIComponent(resolvedPath));
            }
        });

        const images = contentEl.querySelectorAll('img[src]');
        images.forEach(img => {
            const src = img.getAttribute('src');
            if (!src) return;
            if (src.startsWith('data:')) return;
            if (isExternalHref(src)) return;
            if (src.startsWith('/assets/') || src.startsWith('/api/')) return;

            const parts = splitHref(src);
            const resolvedPath = resolveRelativePath(currentFile, parts.path);
            if (!resolvedPath) return;

            if (isImagePath(resolvedPath)) {
                img.setAttribute('src', '/api/file?path=' + encodeURIComponent(resolvedPath));
            }
        });
    }

    // Load file list from API
    async function loadFileList() {
        try {
            const response = await fetch('/api/list');
            if (!response.ok) throw new Error('Failed to load file list');
            fileList = await response.json();
            renderFileList();
        } catch (err) {
            fileListEl.innerHTML = '<div class="error-message">Failed to load files: ' + escapeHtml(err.message) + '</div>';
        }
    }

    // Render file list in sidebar
    function renderFileList() {
        if (fileList.length === 0) {
            fileListEl.innerHTML = '<div class="loading">No markdown files found</div>';
            return;
        }

        fileListEl.innerHTML = fileList.map(file => {
            const isActive = file === currentFile ? 'active' : '';
            return '<a class="file-item ' + isActive + '" href="#" data-path="' + escapeHtml(file) + '">' +
                   escapeHtml(file) + '</a>';
        }).join('');

        // Add click handlers
        fileListEl.querySelectorAll('.file-item').forEach(item => {
            item.addEventListener('click', function(e) {
                e.preventDefault();
                loadFile(this.dataset.path);
            });
        });
    }

    // Load and render a markdown file
    async function loadFile(path, anchor) {
        currentFile = path;

        // Update active state in sidebar
        fileListEl.querySelectorAll('.file-item').forEach(item => {
            item.classList.toggle('active', item.dataset.path === path);
        });

        // Update page title
        document.title = path + ' - Ligi';

        try {
            const response = await fetch('/api/file?path=' + encodeURIComponent(path));
            if (!response.ok) throw new Error('Failed to load file');
            const markdown = await response.text();
            renderMarkdown(markdown);
            if (anchor) {
                scrollToAnchor(anchor);
            }
        } catch (err) {
            contentEl.innerHTML = '<div class="error-message">Failed to load file: ' + escapeHtml(err.message) + '</div>';
        }

        // Update URL hash
        updateHash(path, anchor);
    }

    // Render markdown content
    function renderMarkdown(markdown) {
        // Parse and render markdown
        contentEl.innerHTML = marked.parse(markdown);
        rewriteContentLinks();

        // Highlight code blocks
        highlightCodeBlocks();

        // Process mermaid diagrams
        renderMermaid();

        // Scroll to top
        contentEl.scrollTop = 0;
    }

    // Render mermaid diagrams
    async function renderMermaid() {
        const mermaidBlocks = contentEl.querySelectorAll('.mermaid');
        if (mermaidBlocks.length === 0) return;

        try {
            await mermaid.run({
                nodes: mermaidBlocks
            });
        } catch (err) {
            console.error('Mermaid rendering error:', err);
        }
    }

    // Handle URL hash navigation
    function handleHashChange() {
        const hash = window.location.hash.slice(1);
        if (hash) {
            const decoded = safeDecode(hash);
            const hashIndex = decoded.indexOf('#');
            let path = decoded;
            let anchor = null;
            if (hashIndex !== -1) {
                path = decoded.slice(0, hashIndex);
                anchor = decoded.slice(hashIndex + 1);
            }
            if (path.startsWith('/')) {
                path = path.slice(1);
            }
            const resolved = resolveMarkdownPath(path);
            if (resolved) {
                loadFile(resolved, anchor);
            }
        }
    }

    // Initialize
    async function init() {
        await loadFileList();

        // Check for initial hash
        if (window.location.hash) {
            handleHashChange();
        } else if (fileList.length > 0) {
            // Auto-load first file if no hash
            // loadFile(fileList[0]);
        }
    }

    // Event listeners
    window.addEventListener('hashchange', handleHashChange);
    contentEl.addEventListener('click', function(e) {
        const link = e.target.closest('a[href]');
        if (!link) return;

        const href = link.getAttribute('href');
        if (!href || href.startsWith('#')) return;
        if (isExternalHref(href)) return;
        if (href.startsWith('/assets/') || href.startsWith('/api/')) return;

        const parts = splitHref(href);
        const resolvedPath = resolveRelativePath(currentFile, parts.path);
        const markdownPath = resolvedPath ? resolveMarkdownPath(resolvedPath) : null;

        if (markdownPath) {
            e.preventDefault();
            loadFile(markdownPath, parts.hash || null);
        }
    });

    // Start the app
    init();
})();
