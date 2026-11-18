# Making an extract

This guide shows how to make an extract of your photo storage on your Mac. An extract describes your photos: their names, folders, sizes and dates, together with a copy of your Lightroom Classic catalog. It does not contain the photos themselves. We use it to plan the move of your photos to their new storage.

We go through these steps together with you, at your Mac or in a screen-sharing session. It is simple: a few commands, copied from this guide and pasted into Terminal, the Mac app for typing commands.

No harm can be done. The tool only reads: it never changes, moves or deletes your photos or your Lightroom catalog. The only thing it writes is the extract, in a folder of its own: `photo-analysis` in your home folder.

The first part you do once. After that, making an extract takes a few minutes.

## Before you start: things you do once

### 1. Open Terminal

Press Command and Space together, type `Terminal`, and press Return. A window opens with a line of text ending in `%`. That is where you paste the commands.

To run a command, paste it into the window and press Return. Wait until the `%` line appears again before you paste the next one.

### 2. Install the developer tools

Paste this command:

```
git --version
```

If your Mac shows a version number, such as `git version 2.39.5`, the tools are already installed.

If a window appears asking to install the command line developer tools, click Install and accept the licence. The installation takes a few minutes. When it is done, paste the command again; it now shows a version number.

Then paste this command:

```
python3 --version
```

It shows a version number such as `Python 3.9.6`. Any version from 3.9 onwards is fine.

### 3. Get the extract tool

Paste this command:

```
git clone https://github.com/teunispolak/photo-storage-analyzer ~/photo-storage-analyzer
```

This downloads the tool into a folder called `photo-storage-analyzer` in your home folder. It only reads your files and never changes your photos or your catalog.

### 4. Send us two file locations

We need to know where your Lightroom catalog and your photos are. You can copy each location as text in Finder, and paste it into an email to us:

1. **Your Lightroom catalog.** In Lightroom Classic, choose Catalog Settings (in the Lightroom Classic menu), open the General tab, and click Show next to Location. Finder opens with your catalog file; its name ends in `.lrcat`.
   Select the catalog file in Finder, hold the Option key, right-click it, and choose Copy "…" as Pathname. Paste the result into the email.
2. **Your photo folder.** This is the top folder that holds your photos, often on an external drive. In Lightroom's Library, right-click the top folder in the Folders panel and choose Show in Finder.
   Select the top folder in Finder, hold the Option key, right-click it, and choose Copy "…" as Pathname. Paste the result into the email.

Then send the email.

If your photos are spread over more than one top folder, send us each of them.

### 5. Save the settings file we send you

We reply with a small file called `settings.env`. It tells the tool which catalog and which photo folder to use. Save it in your Downloads folder, then paste this command:

```
mkdir -p ~/photo-analysis && mv ~/Downloads/settings.env ~/photo-analysis/
```

This creates a folder called `photo-analysis` in your home folder and moves the settings file into it.

### 6. Check that the tool can read your catalog

Close Lightroom Classic first. Then paste these two commands, one at a time:

```
cd ~/photo-storage-analyzer
```

```
./psa check-catalog
```

The tool prints a list of checks. If the last line reads `Structure ok`, all is well. If you see lines starting with `FAIL`, give us a call.

## Making an extract

Do this whenever we ask you for an extract.

### 1. Prepare

Connect the drive with your photos, and close Lightroom Classic.

### 2. Make the extract

Open Terminal and paste these two commands, one at a time:

```
cd ~/photo-storage-analyzer
```

```
./psa extract
```

The first time, your Mac may ask whether Terminal may access files on a removable volume, or in a folder such as Pictures. Click Allow; the tool needs this to read the list of your photos.

The tool copies your catalog and reads the list of your photo files, which can take a few minutes for a large collection. It is done when it prints `Extract complete`.

### 3. Send us the extract

Paste this command to open the folder that holds your extract:

```
open ~/photo-analysis/extracts
```

Finder shows a folder whose name starts with the names from your settings file and ends with the date and time, for example `smith_anna_20261118T091500Z`. This is your extract. Right-click it and choose Compress to make a zip file of it, and send us the zip file in the way we agreed.

The extract contains file and folder names, sizes and dates, and a copy of your Lightroom catalog. It contains no photos.

### 4. Tidy up

Once we confirm that we received your extract, you can move the extract folder (for example `smith_anna_20261118T091500Z`) and its zip file from the `extracts` folder in `photo-analysis` to the Bin. The tool never removes anything itself.
