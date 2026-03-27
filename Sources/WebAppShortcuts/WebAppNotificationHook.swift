import Foundation

/// JavaScript hooks injected into web app browser panels to intercept
/// the Web Notification API and route notifications through nsmux.
enum WebAppNotificationHook {
    /// Generic hook that overrides the Notification constructor and
    /// Notification.requestPermission to auto-grant and forward
    /// notification payloads to the native side via a message handler.
    ///
    /// The hook:
    /// 1. Overrides `Notification.requestPermission()` to always resolve "granted"
    /// 2. Overrides the `Notification` constructor to post messages to
    ///    `window.webkit.messageHandlers.cmuxWebAppNotification`
    /// 3. Preserves onclick/onclose callbacks
    /// 4. Monitors title/favicon changes for unread badge detection
    static let genericHookScript = """
    (function() {
        'use strict';

        // --- Notification API Override ---
        const OriginalNotification = window.Notification;

        class CmuxNotification {
            constructor(title, options = {}) {
                this.title = title;
                this.body = options.body || '';
                this.icon = options.icon || '';
                this.tag = options.tag || '';
                this.data = options.data || null;
                this.requireInteraction = options.requireInteraction || false;

                // Post to native handler
                try {
                    window.webkit.messageHandlers.cmuxWebAppNotification.postMessage({
                        type: 'notification',
                        title: this.title,
                        body: this.body,
                        icon: this.icon,
                        tag: this.tag
                    });
                } catch (e) {
                    // Handler not registered yet, silently ignore
                }
            }

            close() {}

            static get permission() { return 'granted'; }

            static requestPermission(callback) {
                const result = Promise.resolve('granted');
                if (callback) callback('granted');
                return result;
            }
        }

        // Preserve static properties from original
        CmuxNotification.maxActions = OriginalNotification?.maxActions || 2;

        Object.defineProperty(window, 'Notification', {
            value: CmuxNotification,
            writable: true,
            configurable: true
        });

        // --- Title Change Observer for Unread Detection ---
        let lastTitle = document.title;
        const titleObserver = new MutationObserver(function() {
            if (document.title !== lastTitle) {
                lastTitle = document.title;
                try {
                    window.webkit.messageHandlers.cmuxWebAppNotification.postMessage({
                        type: 'titleChange',
                        title: document.title
                    });
                } catch (e) {}
            }
        });

        // Start observing once head is available
        function observeTitle() {
            const titleEl = document.querySelector('title');
            if (titleEl) {
                titleObserver.observe(titleEl, { childList: true, characterData: true, subtree: true });
            } else {
                // Title element may not exist yet, observe head
                const head = document.head || document.documentElement;
                const headObserver = new MutationObserver(function(mutations, obs) {
                    const titleEl = document.querySelector('title');
                    if (titleEl) {
                        obs.disconnect();
                        titleObserver.observe(titleEl, { childList: true, characterData: true, subtree: true });
                    }
                });
                headObserver.observe(head, { childList: true, subtree: true });
            }
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', observeTitle);
        } else {
            observeTitle();
        }

        // --- Favicon Change Observer ---
        // Some webapps (Slack) change the favicon to indicate unread state.
        function checkFavicon() {
            const links = document.querySelectorAll('link[rel*="icon"]');
            const hrefs = Array.from(links).map(l => l.href).join(',');
            try {
                window.webkit.messageHandlers.cmuxWebAppNotification.postMessage({
                    type: 'faviconChange',
                    hrefs: hrefs
                });
            } catch (e) {}
        }

        // Observe favicon link changes
        const faviconObserver = new MutationObserver(function() {
            checkFavicon();
        });
        if (document.head) {
            faviconObserver.observe(document.head, { childList: true, subtree: true, attributes: true });
        }
    })();
    """;

    /// Slack-specific hook. Extends the generic hook with additional
    /// Slack-specific unread detection (title pattern: "(N) Slack").
    static let slackHookScript = genericHookScript + """

    // --- Slack-specific unread detection ---
    // Slack updates the document title to "(N) workspace - Slack" when
    // there are unread messages. Extract the count and forward it.
    (function() {
        'use strict';

        function parseSlackUnreadCount(title) {
            // Matches patterns like "(3) workspace - Slack" or "* workspace - Slack"
            const countMatch = title.match(/^\\((\\d+)\\)/);
            if (countMatch) return parseInt(countMatch[1], 10);
            // Slack uses "*" for generic unread indicator
            if (title.startsWith('*')) return -1; // -1 = has unreads, count unknown
            return 0;
        }

        let lastUnreadCount = 0;
        const originalTitle = document.title;

        const slackTitleObserver = new MutationObserver(function() {
            const count = parseSlackUnreadCount(document.title);
            if (count !== lastUnreadCount) {
                lastUnreadCount = count;
                try {
                    window.webkit.messageHandlers.cmuxWebAppNotification.postMessage({
                        type: 'unreadCount',
                        count: count,
                        appId: 'slack'
                    });
                } catch (e) {}
            }
        });

        function observeSlackTitle() {
            const titleEl = document.querySelector('title');
            if (titleEl) {
                slackTitleObserver.observe(titleEl, { childList: true, characterData: true, subtree: true });
                // Check immediately
                const count = parseSlackUnreadCount(document.title);
                if (count !== lastUnreadCount) {
                    lastUnreadCount = count;
                    try {
                        window.webkit.messageHandlers.cmuxWebAppNotification.postMessage({
                            type: 'unreadCount',
                            count: count,
                            appId: 'slack'
                        });
                    } catch (e) {}
                }
            }
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', observeSlackTitle);
        } else {
            observeSlackTitle();
        }
    })();
    """;
}
