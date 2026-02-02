# Smoke Test Checklist

## Backend quick smoke (local)

1. From repo root, run:
   ```bash
   ./scripts/backend_smoke_test.sh
   ```
2. Confirm it completes without errors (health + session create succeed).

## Can run on phone

1. Start the backend on your dev machine:
   ```bash
   cd backend
   go run ./cmd/server
   ```
2. Ensure your phone is on the same network as the dev machine.
3. Find your dev machine IP (e.g., `192.168.1.10`) and set base URL in the app:
   `http://<dev-machine-ip>:8080`
4. Build and run the app on the device:
   ```bash
   cd app
   flutter run -d <device-id>
   ```
5. In the app, tap **Ping Backend** and confirm the status reports success.

## Can send a text transfer

1. Use two devices (Sender and Receiver) on the same network.
2. Receiver: tap **Create Session** and copy the QR payload.
3. Sender: paste the QR payload (or session ID + claim token), enter a sender label.
4. Sender: enable **Send Text** mode, enter a short message, and send.
5. Receiver: approve the claim when prompted.
6. Receiver: confirm the text appears and transfer status shows completed.

## Can save photo to gallery

1. Sender: pick an image file and send it to the Receiver.
2. Receiver: when saving, choose **Photos/Gallery**.
3. If prompted, grant Photos permission and verify the image appears in the Photos app.
4. Deny Photos permission and verify:
   - The app saves to private storage.
   - **Export to Files/Share** is available to move the file out.

## Background download resume (Android + iOS)

1. Receiver: enable **Prefer background downloads** (leave **Show more details in notifications** OFF).
2. Sender: send a large file (>= 8MB) to trigger background download.
3. Receiver: accept the transfer and observe the background notification:
   - Text should read “Receiving transfer…” / “Download in progress”.
   - No filename or sender label should appear by default.
4. Android: background the app, then force-stop/kill it. Confirm the download continues via the notification.
5. iOS: background the app, then swipe it away. Confirm the download continues.
6. Reopen the app after completion:
   - Decrypt+save should complete automatically.
   - Receipt should be sent (transfer removed from backend).
7. Optional: enable **Show more details in notifications** and repeat step 3 to confirm details appear only with opt-in.
