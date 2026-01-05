// Ligi Markdown Viewer Application

(function() {
    'use strict';

    // State
    let currentFile = null;
    let fileList = [];

    // DOM elements
    const fileListEl = document.getElementById('file-list');
    const contentEl = document.getElementById('content');

    // Configure marked for GFM
    marked.setOptions({
        gfm: true,
        breaks: true,
        headerIds: true,
        mangle: false
    });

    // Custom renderer for mermaid blocks
    const renderer = new marked.Renderer();
    const originalCode = renderer.code.bind(renderer);

    renderer.code = function(code, language, escaped) {
        if (language === 'mermaid') {
            return '<div class="mermaid">' + escapeHtml(code) + '</div>';
        }
        return originalCode(code, language, escaped);
    };

    marked.use({ renderer: renderer });

    // Initialize mermaid
    mermaid.initialize({
        startOnLoad: false,
        theme: 'dark',
        securityLevel: 'loose',
        fontFamily: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace'
    });

    // Utility: escape HTML
    function escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
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
    async function loadFile(path) {
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
        } catch (err) {
            contentEl.innerHTML = '<div class="error-message">Failed to load file: ' + escapeHtml(err.message) + '</div>';
        }

        // Update URL hash
        window.location.hash = encodeURIComponent(path);
    }

    // Render markdown content
    function renderMarkdown(markdown) {
        // Parse and render markdown
        contentEl.innerHTML = marked.parse(markdown);

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
            const path = decodeURIComponent(hash);
            if (fileList.includes(path)) {
                loadFile(path);
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

    // Start the app
    init();
})();
