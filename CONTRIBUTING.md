# Contributing to iFace

Thank you for your interest in contributing to **iFace**! We welcome bug reports, feature requests, design enhancements, and code contributions from developers around the world.

---

## How Can You Contribute?

### 1. Suggesting Ideas & Reporting Bugs
If you find a bug or have a suggestion for a new feature (such as new UI animations, additional security checks, or battery optimizations):
* Check the [GitHub Issues](https://github.com/Ankushkushwaha1/iFace/issues) tab to see if it's already being discussed.
* If not, click **"New Issue"** and describe your idea or the bug with steps to reproduce it.

---

### 2. Code Contributions (Fork & Pull Request)

To submit code changes to iFace:

#### Step 1: Fork the Repository
Click the **Fork** button at the top right of the [iFace repository](https://github.com/Ankushkushwaha1/iFace). This creates an independent copy of the project under your own GitHub account.

#### Step 2: Clone Your Fork Locally
```bash
git clone https://github.com/YOUR_USERNAME/iFace.git
cd iFace
```

#### Step 3: Create a Feature Branch
```bash
git checkout -b feature/your-feature-name
```

#### Step 4: Make Changes & Test
1. Open the project in Xcode:
   ```bash
   open iFace.xcodeproj
   ```
2. Build and run on your Mac (`Cmd + R`).
3. Test your changes thoroughly on macOS 15+.

#### Step 5: Commit & Push
```bash
git add .
git commit -m "Add: brief description of your feature"
git push origin feature/your-feature-name
```

#### Step 6: Open a Pull Request (PR)
1. Navigate to your fork on GitHub.
2. Click **"Compare & pull request"**.
3. Describe what your changes do and submit the PR.
4. We will review your code, provide feedback, and merge it!

---

## Code Guidelines
* **Swift & SwiftUI:** Keep views clean and lightweight. Use `@Observable` and Swift concurrency (`async/await`) where appropriate.
* **Privacy First:** Never log, send, or persist unencrypted biometric data or credentials. Everything must remain 100% on-device.
* **Efficiency:** Maintain 0.0% idle background CPU usage.

---

Thank you for helping make iFace better!
