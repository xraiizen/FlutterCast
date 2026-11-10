# FlutterRun + scrcpy (USB → WiFi)

Ce petit outil permet de lancer :

- **scrcpy** (cast Android)
- **flutter run** sur un téléphone **via Wi-Fi**, automatiquement
- bascule USB → WiFi sans configuration manuelle
- et relance rapide sans re-demander les autorisations

Il existe en deux versions : `flutterrun.bat` pour **Windows** et
`flutterrun.sh` pour **Linux** (Linux Mint / Ubuntu / Debian).

---

## 📦 Installation

1. **Télécharger ce dépôt Git**  
   (ZIP ou `git clone`)

2. **Placer le dossier dans :**

```
C:\
```

Vous devez obtenir quelque chose comme :

```
C:\FlutterCast\flutterrun.bat
C:\FlutterCast\scrcpy-win64-xxxx\
C:\FlutterCast\README.md
```

3. **Ajouter le dossier `C:\FlutterCast` dans le PATH Windows**

### Windows 10/11 :

- Ouvrir **Paramètres**
- Système → Informations système
- Paramètres système avancés → Variables d’environnement
- Sélectionner `Path`
- Cliquer sur **Modifier**
- Ajouter :

```
C:\FlutterCast
```

4. Vérifier dans un nouveau terminal :

```
flutterrun
```

Si la commande est reconnue → c’est bon.

---

## 🐧 Installation sous Linux (Linux Mint / Ubuntu / Debian)

Le dossier `scrcpy-win64-v3.3.3` **ne sert pas sous Linux** : on utilise les
paquets système, plus récents et adaptés à la distribution.

### 1. Installer les dépendances

```bash
sudo apt update
sudo apt install adb scrcpy
```

Pour le hot reload automatique (`--watch`), ajoute aussi :

```bash
sudo apt install inotify-tools
```

Vérifier :

```bash
adb version
scrcpy --version
flutter --version
```

### 2. Rendre le script exécutable

Depuis le dossier du dépôt :

```bash
chmod +x flutterrun.sh
```

### 3. Installer la commande `flutterrun` (optionnel mais recommandé)

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/flutterrun.sh" ~/.local/bin/flutterrun
```

Sous Linux Mint, `~/.local/bin` est normalement déjà dans le `PATH`
(via `~/.profile`). Pour l'activer dans le terminal courant :

```bash
source ~/.profile
```

Vérifier :

```bash
flutterrun --help
```

### 4. Utilisation

```bash
cd /chemin/vers/mon_projet_flutter
flutterrun
```

Le script :

- détecte le téléphone en USB ;
- récupère son IP Wi-Fi ;
- active `adb tcpip 5555` et se connecte en Wi-Fi (avec plusieurs tentatives) ;
- lance `scrcpy` ;
- lance `flutter run -d IP:5555`.

Options utiles :

```bash
flutterrun --list              # lister les appareils adb
flutterrun --no-scrcpy         # sans miroir d'écran
flutterrun --no-flutter        # seulement connecter + scrcpy
flutterrun --serial ID         # choisir un appareil
flutterrun --disconnect        # couper la connexion Wi-Fi à la fin
flutterrun -- --release        # passer des arguments à flutter run
```

#### Hot reload automatique (`--watch`)

`flutter run` seul attend que tu appuies sur `r` pour recharger. L'option
`--watch` recharge l'application **automatiquement à chaque sauvegarde** d'un
fichier Dart :

```bash
flutterrun --watch
```

Prérequis (une seule fois) :

```bash
sudo apt install inotify-tools
```

Fonctionnement :

- le script lance `flutter run --pid-file …` ;
- `inotifywait` surveille `lib/` récursivement ;
- à chaque fichier `.dart` sauvegardé, il envoie `SIGUSR1` à Flutter, ce qui
  déclenche un **hot reload** (l'état de l'application est conservé) ;
- les sauvegardes rapprochées sont regroupées (debounce 0.4 s) ;
- `build/`, `.dart_tool/`, `.git/`, `*.g.dart` et `*.freezed.dart` sont
  ignorés pour éviter les rechargements inutiles.

Options associées :

```bash
flutterrun --watch                        # surveille lib/
flutterrun --watch-dir test --watch       # surveille test/ (répétable)
flutterrun --watch --watch-debounce 1     # attend 1 s avant de recharger
flutterrun --watch -- --flavor dev        # transmis à flutter run
```

Quand tu quittes (`q` ou `Ctrl+C`), le script arrête le watcher et nettoie ses
fichiers temporaires.

> Le hot reload ne s'applique pas au code natif Android (`android/`,
> Kotlin/Java), à `pubspec.yaml`, aux permissions ni à certaines ressources.
> Dans ces cas, fais un hot restart (`R`) ou relance `flutterrun`.
>
> Si le projet ne compile pas (erreur dans un fichier en cours d'édition),
> Flutter affiche l'erreur et conserve l'ancienne version à l'écran jusqu'à
> la prochaine sauvegarde valide.

Équivalent dans VS Code : régler
`"dart.flutterHotReloadOnSave": "allIfDirty"` et lancer l'application avec
`F5` (le rechargement est alors géré par l'extension Dart/Flutter).

### 5. Si le téléphone n'est pas détecté

```bash
sudo apt install android-sdk-platform-tools-common
sudo usermod -aG plugdev "$USER"
```

Puis débranche/rebranche le téléphone et reconnecte-toi à la session (ou
redémarre). Vérifie avec :

```bash
adb devices
```

L'état doit être `device`, pas `unauthorized`.

### 6. Sécurité

`adb tcpip 5555` laisse le débogage ouvert sur le réseau local. Pour le
refermer :

```bash
adb usb
```

ou débranche/redémarre le téléphone. Évite ce mode sur un Wi-Fi public.

---

## 📱 Préparation du téléphone Android

1. **Activer les options développeur**
2. Activer **Débogage USB**
3. Brancher le téléphone en USB
4. **Accepter la popup "Autoriser le débogage USB"**

---

## 🚀 Utilisation

Dans n’importe quel projet Flutter :

1. Ouvrir un terminal dans le dossier du projet
2. Exécuter :

```
flutterrun
```

3. Le script va :

   - détecter le téléphone en USB
   - récupérer son IP
   - activer le mode TCP/IP
   - demander d’accepter la popup **Débogage Wi-Fi** si elle apparaît
   - ouvrir scrcpy
   - lancer `flutter run` via Wi-Fi

4. Une fois la connexion Wi-Fi établie, le script indique que le câble USB
   peut être débranché.

➡️ Vous pouvez **débrancher le câble USB**.

---

## 🔁 Utilisation ultérieure (Wi-Fi déjà configuré)

Si le téléphone a déjà été autorisé :

- `flutterrun` va directement se connecter en Wi-Fi
- **scrcpy ne sera pas relancé si déjà ouvert**
- aucune popup ne sera demandée

---

## 🛠 Dépendances (automatiquement vérifiées)

Le script vérifie automatiquement les commandes nécessaires :

- **Windows** : `adb`, `flutter`, `scrcpy.exe`
- **Linux** : `adb`, `flutter`, `scrcpy`

Si quelque chose manque, un message clair s’affiche.

---

## ❓ Problèmes fréquents

### Le cast ne s’ouvre pas

→ Vérifiez que le dossier `scrcpy-win64-v3.3.3` est bien placé à côté de
`flutterrun.bat`.

### Le Wi-Fi ne se connecte pas

→ Vérifiez que le téléphone et le PC sont sur le **même réseau Wi-Fi**.
→ Acceptez la popup “Débogage Wi-Fi” si elle apparaît.

### "Device unauthorized"

→ Débranchez/Rebranchez en USB et réacceptez la popup USB.

### Sous Linux : "Aucun téléphone utilisable détecté"

→ `adb devices` doit afficher l'état `device` (et non `unauthorized`).
→ Si le téléphone n'apparaît pas du tout :

```bash
sudo apt install android-sdk-platform-tools-common
sudo usermod -aG plugdev "$USER"
```

Puis débranchez/rebranchez le téléphone et reconnectez-vous à la session.

### Sous Linux : "Connexion Wi-Fi impossible"

→ Vérifiez que le téléphone est bien connecté au Wi-Fi (pas seulement en 4G/5G).
→ Vérifiez que le PC et le téléphone sont sur le même sous-réseau.
→ Réessayez avec `flutterrun --list` pour voir l'état des appareils.

---

## ✔️ C’est tout !

Le script est maintenant prêt pour un usage quotidien simple, rapide et fiable.
