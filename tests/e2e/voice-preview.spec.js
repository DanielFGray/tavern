const { test, expect } = require('@playwright/test')

const { command, login } = require('./support')

// Chromium's fake devices stand in for the camera, the microphone and the screen picker. The
// Realtime API is stubbed (`stub_voice`), so nothing is relayed: this spec checks only what a tab
// shows of its own media, which never passes through the SFU anyway.
test.use({
  launchOptions: {
    args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'],
  },
})

test.skip(({ browserName, isMobile }) => browserName !== 'chromium' || isMobile, 'needs Chromium fake media')

const playing = (video) => video.evaluate((el) => el.videoWidth > 0 && !el.paused)

test('your own camera and screen play in your tile and survive re-renders', async ({ page, request }) => {
  // A publish whose offer and answer cross shows up only as a page error or a warning.
  const faults = []
  page.on('pageerror', (err) => faults.push(err.message))
  page.on('console', (msg) => msg.text().startsWith('voice publish failed') && faults.push(msg.text()))

  await command(request, 'stub_voice')
  await command(request, 'ensure_channel', { slug: 'e2e-voice-preview', name: 'voice-preview', kind: 'voice' })
  await login(page, { next: '/?channel=e2e-voice-preview' })

  await page.locator('#voice-join-button').click()
  await expect(page.locator('#voice-mic-toggle')).toBeVisible()

  await page.locator('#voice-camera-toggle').click()
  await expect(page.locator('#voice-camera-toggle')).toHaveAttribute('aria-pressed', 'true')
  const camera = page.locator('[id^="voice-video-"][id$="-camera"] video')
  await expect.poll(() => playing(camera)).toBe(true)

  // Muting re-renders the tile; the hook's <video> must stay where it is.
  await page.locator('#voice-mic-toggle').click()
  await expect(page.locator('#voice-mic-toggle')).toHaveAttribute('aria-pressed', 'true')
  await expect(camera).toHaveCount(1)
  expect(await playing(camera)).toBe(true)

  await page.locator('#voice-screen-toggle').click()
  await expect(page.locator('#voice-screen-toggle')).toHaveAttribute('aria-pressed', 'true')
  const screen = page.locator('[id^="voice-video-"][id$="-screen"] video')
  await expect.poll(() => playing(screen)).toBe(true)

  // Stopping the screen removes its area and leaves the camera playing.
  await page.locator('#voice-screen-toggle').click()
  await expect(page.locator('#voice-screen-toggle')).toHaveAttribute('aria-pressed', 'false')
  await expect(screen).toHaveCount(0)
  expect(await playing(camera)).toBe(true)
  expect(faults).toEqual([])
})
