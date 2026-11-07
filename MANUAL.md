# NTFS Bridge — User Manual / Εγχειρίδιο Χρήσης

> **English below** — για Ελληνικά, δείτε το [Μέρος Β](#μερος-β-οδηγίες-στα-ελληνικά).

---

## PART A — Instructions in English

### 1. What this app does

NTFS Bridge is a native macOS app that lets you use an **existing
NTFS-formatted external drive** (for example a 1 TB Toshiba disk full of
files) on your Mac: view it on a dashboard, copy folders to it with
checksum verification, and eject it safely — **without formatting it**,
so it keeps working on Windows.

One important fact first: **macOS can only read NTFS by itself.** NTFS
Bridge therefore ships its own proven write engine (**NTFS-3G 2026.9.28**,
built from pinned open-source code — provenance in
`Resources/engine-info.json`). The engine needs **FUSE-T** (free) as a
one-time system companion: kext-free, no Recovery-mode step. If either
piece is missing, the app honestly shows the drive as **Read-only** and
refuses to copy. Nothing is faked.

### 2. Requirements

- macOS Ventura 13 or newer (macOS 26 recommended).
- Apple Silicon (M1–M4) or Intel Mac.
- An external USB / USB-C drive formatted as NTFS.
- Xcode 16+ (only if you want to build from source; the ready-made
  `dist/NTFSBridge.app` needs nothing extra).
- Administrator password (macOS will ask for it when enabling write).

### 3. One-time setup: FUSE-T companion (required for writing)

The write engine ships inside NTFS Bridge, but it needs the free
**FUSE-T** runtime once — no Terminal, no Homebrew:

1. Download FUSE-T from its official site (`fuse-t.org`) and run the
   installer (free for non-commercial use). Kext-free: no Recovery mode,
   no reduced security.
2. Press **Refresh** in NTFS Bridge. The driver checklist shows the FUSE
   runtime as found.

Without this step, drives stay read-only. (Advanced: existing Homebrew
FUSE-T, FSKit drivers such as NTFS4Mac/NTFSTool on macOS 26+, or
commercial drivers like Paragon/Tuxera/iBoysoft are all detected
automatically — the app always prefers its bundled engine. FUSE-T alone
is not enough without the engine, and the engine alone is not enough
without a FUSE runtime: the checklist shows exactly which piece is
missing.)

### 4. Build and launch the app

Easiest: double-click **`start.command`** in the `ntfs-bridge` folder —
it builds the app on first run, then opens it. Or manually:

```bash
cd ntfs-bridge
./scripts/build-app.sh
open dist/NTFSBridge.app
```

On first launch, if macOS says the app is from an unidentified developer
(the bundle is ad-hoc signed), right-click it and choose **Open**, then
confirm. Developers can also run `swift build`, `swift test` (52 unit
tests plus 4 NTFS integration tests, all must pass), or
`swift run NTFSBridgeApp`.

### 5. Connect your drive and read the dashboard

1. Plug in the NTFS drive.
2. Press **Refresh** (toolbar, circular-arrow button).
3. Each external drive shows: name, filesystem, total capacity, free
   space, and a badge — **Read-only** (orange lock), **Read & write**
   (green seal), or **Not mounted**. Non-NTFS drives show their own
   filesystem name.
4. Below the header you see a capacity bar, an **NTFS driver status**
   checklist (NTFS-3G binary, FUSE runtime, FSKit module, commercial
   driver, live writable mount — each with ✓ or ✗ and what it means),
   and the last health-check result. If you already installed a driver
   and the app still says read-only, this list tells you exactly which
   piece it cannot see.

### 6. Enable NTFS write (health check first)

1. Select the NTFS drive and press **Check health**. The app runs a
   read-only verification and looks for a Windows hibernation marker.
2. If it reports a dirty journal or hibernation, **stop**: plug the drive
   into Windows, shut Windows down cleanly (no hibernate/fast-startup),
   optionally run `chkdsk`, then retry. NTFS Bridge will keep the drive
   read-only until it is clean — that is protecting your data.
3. Press **Enable NTFS write…** and read the sheet:
   - *No engine*: it tells you to update NTFS Bridge / install FUSE-T
     (section 3). Nothing happens.
   - *NTFS-3G*: it unmounts and remounts via the bundled engine after one
     macOS administrator prompt. Nothing is formatted or erased.
   - *FSKit / commercial*: the installed driver owns mounting — open the
     vendor app, approve its extension if asked, then press **Refresh**.
4. The badge flips to **Read & write** only when the kernel confirms the
   volume truly mounted writable. A remount the system still reports as
   read-only stays read-only, with an explanation — never a faked badge.

### 7. Copy files to the drive

1. Keep **“Allow overwriting” OFF** unless you really mean to replace
   files. With it off, any existing destination file aborts the job and
   **nothing is overwritten**.
2. Add files any of three ways:
   - drag folders onto the dashed **drop zone**;
   - press **Choose files…** and pick them in the file panel;
   - copy files in Finder, then press **Paste from clipboard**.
3. Watch the transfer card: progress bar, bytes copied / total, speed,
   estimated time left, and the file currently copying.
4. You can **Cancel** mid-copy; partial files are removed automatically.
   A failed job names the cause and offers **Retry**.
5. Every file is **SHA-256 checksum-verified**; a mismatch deletes the
   bad copy and reports failure. Sources are never modified or deleted.

### 8. Manage files on the drive

Once the badge reads **Read & write**, the “Manage files on this drive”
section unlocks (it stays disabled on read-only volumes):

- **Create folder**: type a name and press Create folder.
- **Rename a file or folder…**: pick the item, type the new name, press
  Rename. Renaming never overwrites — an existing name stops the rename.
- **Delete files…**: pick the items, review the red confirmation panel
  listing each one, then press **Delete permanently** (or Cancel). There
  is no undo. Deletion is always confined to the selected drive, and the
  drive itself can never be renamed or deleted.

### 9. Eject safely and review the log

1. Press **Eject safely** and wait for confirmation **before** unplugging.
   If an eject fails, re-plug and eject cleanly before writing again.
2. The **Activity log** at the bottom records every detection, health
   check, copy, error, and eject. It is also saved permanently at
   `~/Library/Application Support/NTFSBridge/` for later diagnosis.

### 10. Practice without risk

- `./scripts/create-test-image.sh` mounts a disposable 2 GB test volume
  in `/Volumes/NTFSBRIDGE-TEST`. Copy there first, then detach it and
  delete the image. Only touch the real 1 TB drive after a clean test.
- Never format, erase, or repartition the drive — the app contains no
  such function at all, by design.

### 11. Troubleshooting

| Symptom | What to do |
|---|---|
| No drives at all, drive plugged in | Read the note under the empty list: it names every volume macOS reports. If yours is missing, macOS never mounted it — try another cable/port, check Disk Utility, then Refresh. A greyed-out disk in Disk Utility means: select it in NTFS Bridge and press **Mount**. |
| Drive shows “Not mounted” | Select it and press **Mount** (mounting never formats or erases). If Mount fails, clean the drive on Windows (`chkdsk`, full shutdown) and retry. |
| Drive shows Read-only | Install FUSE-T (section 3), then Refresh. The checklist names the missing piece. |
| Health check fails | Clean the drive on Windows (`chkdsk`, full shutdown), retry. |
| Remount asks for password | Normal: macOS itself prompts once for the NTFS-3G remount. |
| Copy refuses “File exists” | Destination file exists and overwrite is off — intended protection. Tick overwrite only deliberately. |
| “Clipboard has no files” | Copy files (not text) in Finder first. |
| Bad copy reported | Retry; if it repeats, check the cable/port and disk health. |

### 12. Uninstall

Delete `NTFSBridge.app`; optionally delete
`~/Library/Application Support/NTFSBridge/`. Remove FUSE-T or any other
driver with its own uninstaller. The drive returns to Apple's
safe read-only NTFS handling — still NTFS, still Windows-compatible.

---

## ΜΕΡΟΣ Β — Οδηγίες στα Ελληνικά

### 1. Τι κάνει αυτή η εφαρμογή

Το NTFS Bridge είναι μια γνήσια εφαρμογή macOS που σας επιτρέπει να
χρησιμοποιείτε έναν **υπάρχοντα εξωτερικό δίσκο σε μορφή NTFS** (π.χ. έναν
Toshiba 1 TB γεμάτο αρχεία) στο Mac: τον βλέπετε στον πίνακα, αντιγράφετε
φακέλους με έλεγχο ακεραιότητας και τον αποσυνδέετε με ασφάλεια —
**χωρίς format**, ώστε να συνεχίζει να δουλεύει στα Windows.

Ένα σημαντικό γεγονός εξαρχής: **το macOS από μόνο του διαβάζει μόνο
NTFS.** Το NTFS Bridge γι' αυτό φέρνει δική του δοκιμασμένη μηχανή εγγραφής
(**NTFS-3G 2026.9.28**, χτισμένη από ανοιχτό κώδικα — προέλευση στο
`Resources/engine-info.json`). Η μηχανή θέλει το **FUSE-T** (δωρεάν) ως
συνοδό μία φορά: χωρίς kernel extension, χωρίς Recovery. Αν λείπει κάποιο
από τα δύο κομμάτια, η εφαρμογή δείχνει τον δίσκο ως **Μόνο ανάγνωση** και
αρνείται την αντιγραφή. Τίποτα δεν προσποιείται.

### 2. Απαιτήσεις

- macOS Ventura 13 ή νεότερο (προτείνεται macOS 26).
- Mac με Apple Silicon (M1–M4) ή Intel.
- Εξωτερικός δίσκος USB / USB-C σε μορφή NTFS.
- Xcode 16+ (μόνο αν θέλετε να το χτίσετε από τον κώδικα· το έτοιμο
  `dist/NTFSBridge.app` δεν χρειάζεται τίποτα επιπλέον).
- Κωδικός διαχειριστή (το macOS θα τον ζητήσει κατά την ενεργοποίηση
  της εγγραφής).

### 3. Ρύθμιση μία φορά: συνοδός FUSE-T (απαραίτητο για εγγραφή)

Η μηχανή εγγραφής έρχεται μέσα στο NTFS Bridge, αλλά θέλει μία φορά το
δωρεάν **FUSE-T** — χωρίς Terminal, χωρίς Homebrew:

1. Κατεβάστε το FUSE-T από την επίσημη σελίδα του (`fuse-t.org`) και
   τρέξτε τον εγκαταστάτη (δωρεάν για μη εμπορική χρήση). Χωρίς kernel
   extension: ούτε Recovery ούτε μειωμένη ασφάλεια.
2. Πατήστε **Refresh** στο NTFS Bridge. Η λίστα οδηγών δείχνει το FUSE
   ως εγκατεστημένο.

Χωρίς αυτό το βήμα, οι δίσκοι παραμένουν μόνο για ανάγνωση. (Για
προχωρημένους: υπάρχον FUSE-T από Homebrew, οδηγοί FSKit όπως
NTFS4Mac/NTFSTool σε macOS 26+, ή εμπορικοί οδηγοί όπως
Paragon/Tuxera/iBoysoft εντοπίζονται αυτόματα — η εφαρμογή προτιμά πάντα
τη δική της ενσωματωμένη μηχανή.)

### 4. Χτίσιμο και εκκίνηση της εφαρμογής

Ευκολότερα: διπλό κλικ στο **`start.command`** μέσα στον φάκελο
`ntfs-bridge` — χτίζει την εφαρμογή την πρώτη φορά και μετά την ανοίγει.
Ή χειροκίνητα:

```bash
cd ntfs-bridge
./scripts/build-app.sh
open dist/NTFSBridge.app
```

Στην πρώτη εκκίνηση, αν το macOS πει ότι η εφαρμογή προέρχεται από
μη ταυτοποιημένο προγραμματιστή (το πακέτο είναι ad-hoc υπογεγραμμένο),
κάντε δεξί κλικ και επιλέξτε **Άνοιγμα** και επιβεβαιώστε. Οι
προγραμματιστές μπορούν επίσης να τρέξουν `swift build`, `swift test`
(52 unit τεστ συν 4 τεστ ολοκλήρωσης NTFS, πρέπει να περνούν όλα) ή
`swift run NTFSBridgeApp`.

### 5. Συνδέστε τον δίσκο και διαβάστε τον πίνακα

1. Συνδέστε τον δίσκο NTFS.
2. Πατήστε **Refresh** (εργαλειοθήκη, κουμπί με κυκλικό βέλος).
3. Κάθε εξωτερικός δίσκος δείχνει: όνομα, σύστημα αρχείων, συνολική
   χωρητικότητα, ελεύθερο χώρο και σήμα — **Read-only** (πορτοκαλί
   λουκέτο), **Read & write** (πράσινη σφραγίδα) ή **Not mounted**. Οι
   μη-NTFS δίσκοι δείχνουν το δικό τους σύστημα αρχείων.
4. Κάτω από την επικεφαλίδα βλέπετε μπάρα χωρητικότητας, μια λίστα
   **κατάστασης οδηγού NTFS** (δυαδικό NTFS-3G, χρόνος εκτέλεσης FUSE,
   μονάδα FSKit, εμπορικός οδηγός, ενεργή προσάρτηση με εγγραφή —
   το καθένα με ✓ ή ✗ και τι σημαίνει) και το αποτέλεσμα του τελευταίου
   ελέγχου υγείας. Αν έχετε ήδη εγκαταστήσει οδηγό και η εφαρμογή λέει
   ακόμα μόνο για ανάγνωση, αυτή η λίστα δείχνει ακριβώς ποιο κομμάτι
   δεν βλέπει.

### 6. Ενεργοποίηση εγγραφής NTFS (πρώτα έλεγχος υγείας)

1. Επιλέξτε τον δίσκο NTFS και πατήστε **Check health**. Η εφαρμογή κάνει
   έλεγχο μόνο για ανάγνωση και ψάχνει για δείκτη αδρανοποίησης Windows.
2. Αν αναφέρει βρώμικο ημερολόγιο ή αδρανοποίηση, **σταματήστε**: συνδέστε
   τον δίσκο στα Windows, κλείστε τα Windows κανονικά (όχι αδρανοποίηση /
   γρήγορη εκκίνηση), προαιρετικά τρέξτε `chkdsk` και ξαναδοκιμάστε. Το
   NTFS Bridge κρατά τον δίσκο μόνο για ανάγνωση μέχρι να καθαρίσει —
   έτσι προστατεύει τα δεδομένα σας.
3. Πατήστε **Enable NTFS write…** και διαβάστε το παράθυρο:
   - *Χωρίς μηχανή*: σας λέει να ενημερώσετε το NTFS Bridge / να βάλετε
     FUSE-T (ενότητα 3). Δε γίνεται τίποτα.
   - *NTFS-3G*: αποπροσαρτά και επαναπροσαρτά μέσω της ενσωματωμένης
     μηχανής μετά από ένα αίτημα κωδικού διαχειριστή από το macOS. Δε
     γίνεται format ούτε σβήσιμο.
   - *FSKit / εμπορικό*: την προσάρτηση τη διαχειρίζεται ο εγκατεστημένος
     οδηγός — ανοίξτε την εφαρμογή του, εγκρίνετε την επέκταση αν
     ζητηθεί και πατήστε **Refresh**.
4. Το σήμα γίνεται **Read & write** μόνο όταν το σύστημα επιβεβαιώσει ότι
   ο τόμος προσαρτήθηκε πραγματικά για εγγραφή. Επαναπροσάρτηση που το
   σύστημα εξακολουθεί να δείχνει μόνο για ανάγνωση παραμένει μόνο για
   ανάγνωση, με εξήγηση — ποτέ πλαστό σήμα.

### 7. Αντιγραφή αρχείων στον δίσκο

1. Κρατήστε το **«Allow overwriting» ΚΛΕΙΣΤΟ**, εκτός αν θέλετε
   πραγματικά να αντικαταστήσετε αρχεία. Όταν είναι κλειστό, κάθε
   υπάρχον αρχείο προορισμού σταματά την εργασία και **τίποτα δεν
   αντικαθίσταται**.
2. Προσθέστε αρχεία με έναν από τρεις τρόπους:
   - σύρετε φακέλους στη διακεκομμένη **ζώνη απόθεσης**·
   - πατήστε **Choose files…** και διαλέξτε από τον διάλογο·
   - αντιγράψτε αρχεία στο Finder και πατήστε **Paste from clipboard**.
3. Παρακολουθήστε την κάρτα μεταφοράς: μπάρα προόδου, byte που
   αντιγράφηκαν / σύνολο, ταχύτητα, υπολειπόμενος χρόνος και το αρχείο
   που αντιγράφεται εκείνη τη στιγμή.
4. Μπορείτε να πατήσετε **Cancel** στη μέση· τα ημιτελή αρχεία
   διαγράφονται αυτόματα. Μια αποτυχημένη εργασία αναφέρει την αιτία και
   προσφέρει **Retry**.
5. Κάθε αρχείο **επαληθεύεται με άθροισμα SHA-256**· σε αναντιστοιχία το
   κακό αντίγραφο σβήνεται και αναφέρεται αποτυχία. Οι πηγές δεν
   τροποποιούνται ούτε διαγράφονται ποτέ.

### 8. Διαχείριση αρχείων στον δίσκο

Όταν το σήμα γράφει **Read & write**, ξεκλειδώνει η ενότητα «Manage files
on this drive» (παραμένει κλειδωμένη στους τόμους μόνο για ανάγνωση):

- **Create folder**: γράφετε όνομα και πατάτε Create folder.
- **Rename a file or folder…**: διαλέγετε το στοιχείο, γράφετε το νέο
  όνομα, πατάτε Rename. Η μετονομασία δεν αντικαθιστά ποτέ — υπάρχον
  όνομα σταματά τη μετονομασία.
- **Delete files…**: διαλέγετε τα στοιχεία, ελέγχετε τον κόκκινο πίνακα
  επιβεβαίωσης που τα απαριθμεί και πατάτε **Delete permanently** (ή
  Cancel). Δεν υπάρχει αναίρεση. Η διαγραφή περιορίζεται πάντα στον
  επιλεγμένο δίσκο, και ο ίδιος ο δίσκος δεν μετονομάζεται ούτε
  διαγράφεται ποτέ.

### 9. Ασφαλής αποσύνδεση και έλεγχος καταγραφής

1. Πατήστε **Eject safely** και περιμένετε επιβεβαίωση **πριν** βγάλετε το
   καλώδιο. Αν η αποσύνδεση αποτύχει, ξανασυνδέστε και αποσυνδέστε
   κανονικά πριν ξαναγράψετε.
2. Το **Activity log** στο κάτω μέρος καταγράφει κάθε εντοπισμό, έλεγχο
   υγείας, αντιγραφή, σφάλμα και αποσύνδεση. Αποθηκεύεται μόνιμα στο
   `~/Library/Application Support/NTFSBridge/` για μελλοντική διάγνωση.

### 10. Εξασκηθείτε χωρίς ρίσκο

- Το `./scripts/create-test-image.sh` προσαρτά έναν αναλώσιμο τόμο δοκιμής
  2 GB στο `/Volumes/NTFSBRIDGE-TEST`. Αντιγράψτε εκεί πρώτα, μετά
  αποσυνδέστε τον και σβήστε την εικόνα. Αγγίξτε τον πραγματικό δίσκο του
  1 TB μόνο μετά από καθαρή δοκιμή.
- Ποτέ μην κάνετε format, erase ή repartition στον δίσκο — η εφαρμογή δεν
  περιέχει καμία τέτοια λειτουργία, εκ σχεδιασμού.

### 11. Αντιμετώπιση προβλημάτων

| Σύμπτωμα | Τι να κάνετε |
|---|---|
| Καθόλου δίσκοι ενώ είναι συνδεδεμένος | Διαβάστε τη σημείωση κάτω από την άδεια λίστα: αναφέρει όλους τους τόμους που βλέπει το macOS. Αν ο δικός σας λείπει, το macOS δεν τον προσάρτησε ποτέ — δοκιμάστε άλλο καλώδιο/θύρα, ελέγξτε την Επιφάνεια Εργασίας Δίσκων (Disk Utility) και πατήστε Refresh. Γκρι δίσκος εκεί σημαίνει: επιλέξτε τον στο NTFS Bridge και πατήστε **Mount**. |
| Ο δίσκος δείχνει «Not mounted» | Επιλέξτε τον και πατήστε **Mount** (η προσάρτηση δεν κάνει ποτέ format ούτε σβήσιμο). Αν αποτύχει, καθαρίστε τον στα Windows (`chkdsk`, πλήρης τερματισμός) και ξαναδοκιμάστε. |
| Ο δίσκος δείχνει Read-only | Εγκαταστήστε το FUSE-T (ενότητα 3) και πατήστε Refresh. Η λίστα δείχνει ποιο κομμάτι λείπει. |
| Ο έλεγχος υγείας αποτυγχάνει | Καθαρίστε τον δίσκο στα Windows (`chkdsk`, πλήρης τερματισμός) και ξαναδοκιμάστε. |
| Ζητά κωδικό η επαναπροσάρτηση | Φυσιολογικό: το ίδιο το macOS ζητά μία φορά τον κωδικό για την επαναπροσάρτηση NTFS-3G. |
| Η αντιγραφή αρνείται «File exists» | Το αρχείο προορισμού υπάρχει και η αντικατάσταση είναι κλειστή — σκόπιμη προστασία. Ανοίξτε την αντικατάσταση μόνο συνειδητά. |
| «Clipboard has no files» | Αντιγράψτε πρώτα αρχεία (όχι κείμενο) στο Finder. |
| Αναφέρεται κακό αντίγραφο | Ξαναδοκιμάστε· αν επαναληφθεί, ελέγξτε καλώδιο/θύρα και την υγεία του δίσκου. |

### 12. Απεγκατάσταση

Σβήστε το `NTFSBridge.app`· προαιρετικά σβήστε το
`~/Library/Application Support/NTFSBridge/`. Αφαιρέστε το FUSE-T ή
οποιονδήποτε άλλο οδηγό με τον δικό του απεγκαταστάτη. Ο
δίσκος επιστρέφει στον ασφαλή χειρισμό NTFS μόνο για ανάγνωση της Apple —
παραμένει NTFS και συμβατός με Windows.

