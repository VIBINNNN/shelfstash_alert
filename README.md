ShelfStash Alert

1. Introduction

ShelfStash Alert is a simple pantry tracking app I built using Flutter.
The main purpose of this project is to help users keep track of food expiry dates so they don’t accidentally waste food. The app lets users add items, edit them, get expiry reminders, and view recipe suggestions.


2. What the App Can Do

* Add new pantry items with name, notes, and expiry date
* Edit existing items anytime
* Automatically notify the user when:

  * an item is **almost expiring**, or
  * an item is **already expired**
* Show recipe suggestions based on what items the user has
* Show a custom “Item Saved” popup with:

  * a big green tick
  * text that says “Item saved”
  * confetti inside the box
* Works in browser on laptop AND on my iPhone through local hosting

3. How I Built It

I used Flutter because it allows me to create apps that run on both web and mobile with one codebase.

Some Flutter features I used:

* ValueNotifiers for updating the UI in real-time
* Timers to check expiry dates every minute
* Custom animations and drawing code for confetti
* HTML audio for sound effects on web
* Dialogs and overlays for user interaction


4. How to Run the App

On Laptop (Chrome)

flutter run -d chrome

On iPhone (local web hosting)

1. Run this in VS Code:
   flutter run -d web-server --web-hostname=0.0.0.0 --web-port=8080
2. Get your laptop's IP using:

   ipconfig
3. On iPhone Safari, type:

   http://YOUR_IP:8080
  

This will load the app on your phone.

4. Summary of My Work

* Designed the UI and pages
* Built the logic for adding/editing items
* Added expiry check system
* Added notifications and sound alerts
* Made a confetti animation for the save popup
* Tested on laptop and iPhone
* Fixed bugs (dialog stuck, blank box, confetti issues)
* Hosted locally


If you want, I can also write a shorter or more formal version depending on what your lecturer p
