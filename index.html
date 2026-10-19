<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Liste des fichiers du dépôt</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; max-width: 600px; margin: 40px auto; padding: 20px; background: #f6f8fa; color: #24292f; }
        h1 { text-align: center; font-size: 24px; margin-bottom: 20px; }
        .list-container { background: white; padding: 10px 20px; border: 1px solid #d0d7de; border-radius: 6px; }
        ul { list-style: none; padding: 0; margin: 0; }
        li { display: flex; justify-content: space-between; align-items: center; padding: 16px 0; border-bottom: 1px solid #d0d7de; }
        li:last-child { border-bottom: none; }
        .filename { font-weight: 600; font-size: 14px; }
        .btn { background-color: #2ea44f; color: white; text-decoration: none; padding: 6px 12px; border-radius: 6px; font-size: 14px; font-weight: 500; display: inline-block; }
        .btn:hover { background-color: #2c974b; }
        .status { text-align: center; color: #57606a; font-style: italic; padding: 20px 0; }
    </style>
</head>
<body>

    <h1>Fichiers disponibles</h1>
    <div class="list-container">
        <ul id="file-list">
            <li class="status" id="status-message">Détection des fichiers en cours...</li>
        </ul>
    </div>

    <script>
        async function loadCurrentRepoFiles() {
            const listElement = document.getElementById('file-list');
            const statusMessage = document.getElementById('status-message');

            try {
                // Détecte automatiquement l'utilisateur et le dépôt depuis l'URL GitHub Pages
                const hostname = window.location.hostname;
                const pathSegments = window.location.pathname.split('/').filter(Boolean);

                if (hostname === 'localhost' || window.location.protocol === 'file:') {
                    statusMessage.innerHTML = "Pour tester en local, vous devez héberger la page en ligne sur GitHub Pages ou renseigner manuellement vos identifiants dans le code.";
                    return;
                }

                const username = hostname.split('.')[0];
                const repo = pathSegments[0];

                // Appel à l'API GitHub
                const apiUrl = `https://github.com{username}/${repo}/contents/`;
                
                const response = await fetch(apiUrl);
                if (!response.ok) throw new Error('Impossible de lire le dépôt');

                const items = await response.json();
                
                // Filtre pour ne garder que les fichiers (pas les dossiers) et exclure index.html
                const files = items.filter(item => item.type === 'file' && item.name.toLowerCase() !== 'index.html');

                if (files.length === 0) {
                    statusMessage.innerText = 'Aucun fichier disponible dans ce dépôt.';
                    return;
                }

                // Vide le message de chargement
                listElement.innerHTML = '';

                // Génère dynamiquement la liste de tous les fichiers
                files.forEach(file => {
                    const li = document.createElement('li');
                    li.innerHTML = `
                        <span class="filename">📄 ${file.name}</span>
                        <a href="${file.download_url}" class="btn" download>Télécharger</a>
                    `;
                    listElement.appendChild(li);
                });

            } catch (error) {
                statusMessage.innerText = `Erreur lors du chargement : ${error.message}`;
                statusMessage.style.color = '#cf222e';
            }
        }

        loadCurrentRepoFiles();
    </script>
</body>
</html>
