# FarmerPlus PWA

FarmerPlus is an installable browser app for farm records, field mapping, offline work and learning.

## Build the PWA

You need Node.js and the Flutter SDK version supported by `pubspec.yaml`.

```powershell
npm ci
npm run build:pwa
```

The built web app is written to `build/web`.

## Run the local application

The full local preview uses the sibling Farmer Backend project. Follow [the local development guide](docs/LOCAL-DEVELOPMENT.md) for setup, configuration and run commands.

The browser app is designed to connect to a separately configured backend. Building this repository alone does not deploy or configure backend services.
