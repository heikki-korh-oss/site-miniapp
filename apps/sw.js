self.addEventListener('notificationclick', function(event) {
    event.notification.close();
    event.waitUntil(clients.matchAll({ type: 'window' }).then(windowClients => {
        if (windowClients.length > 0) {
            return windowClients[0].focus();
        }
    }));
});
