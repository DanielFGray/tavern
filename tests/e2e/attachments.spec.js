const { test, expect } = require('@playwright/test')

const { login, unique } = require('./support')

// A 1x1 PNG. Each test appends its own suffix in the file name, not the bytes.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
  'base64',
)

const composer = page => page.locator('#message-form [contenteditable="true"]').first()

test.beforeEach(async ({ page, isMobile }) => {
  test.skip(isMobile, 'the composer is the same on a phone; the e2e WebKit build is not installed')

  await page.addInitScript(() => {
    window.__cspViolations = []
    document.addEventListener('securitypolicyviolation', (event) =>
      window.__cspViolations.push(`${event.violatedDirective} ${event.blockedURI}`),
    )
  })
})

test('a picked image previews, sends with Enter alone and loads in the transcript', async ({ page }, testInfo) => {
  const name = `pic-${unique(testInfo)}.png`
  await login(page, { next: '/?channel=general' })

  await page.locator('#message-form input[type="file"]').setInputFiles({ name, mimeType: 'image/png', buffer: PNG })

  const pending = page.locator('#composer-attachments [data-pending-attachment]')
  await expect(pending).toHaveCount(1)
  await expect(pending).toContainText(name)
  await expect(pending.locator('img')).toHaveJSProperty('complete', true)

  await composer(page).click()
  await composer(page).press('Enter')

  const image = page.locator(`#message-list a[aria-label="Open ${name}"] img`)
  await expect(image).toBeVisible()
  await expect.poll(() => image.evaluate(img => img.naturalWidth)).toBe(1)
  await expect(page.locator('#composer-attachments')).toHaveCount(0)

  expect(await page.evaluate(() => window.__cspViolations)).toEqual([])
})

test('a pasted file joins the waiting files, and a non-image downloads under its name', async ({ page }, testInfo) => {
  const name = `notes-${unique(testInfo)}.txt`
  await login(page, { next: '/?channel=general' })

  await composer(page).click()
  await composer(page).evaluate((editor, name) => {
    const data = new DataTransfer()
    data.items.add(new File(['plain words'], name, { type: 'text/plain' }))
    editor.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }))
  }, name)

  await expect(page.locator('#composer-attachments [data-pending-attachment]')).toContainText(name)
  await expect(composer(page)).toHaveText('')

  // Spreadsheet cells arrive as text and a picture of them; the text wins.
  await composer(page).evaluate((editor) => {
    const data = new DataTransfer()
    data.setData('text/plain', 'cell text')
    data.items.add(new File([new Uint8Array([137, 80, 78, 71])], 'cells.png', { type: 'image/png' }))
    editor.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }))
  })
  await expect(composer(page)).toHaveText('cell text')
  await expect(page.locator('#composer-attachments [data-pending-attachment]')).toHaveCount(1)
  await composer(page).press('ControlOrMeta+a')
  await composer(page).press('Backspace')

  await composer(page).pressSequentially('see attached')
  await composer(page).press('Enter')

  const card = page.locator(`#message-list a[download="${name}"]`)
  await expect(card).toBeVisible()

  const response = await page.request.get(await card.getAttribute('href'))
  expect(response.status()).toBe(200)
  expect(response.headers()['content-type']).toBe('application/octet-stream')
  expect(response.headers()['content-disposition']).toContain(`attachment; filename="${name}"`)
  expect(await response.text()).toBe('plain words')
})

// ProseMirror handles drops inside the editor itself, so the drop lands on the editor, not
// beside it, to prove the composer's drop target still receives the file.
test('a file dropped on the editor joins the waiting files', async ({ page }, testInfo) => {
  const name = `dropped-${unique(testInfo)}.png`
  await login(page, { next: '/?channel=general' })

  const dataTransfer = await page.evaluateHandle(({ name, bytes }) => {
    const data = new DataTransfer()
    data.items.add(new File([new Uint8Array(bytes)], name, { type: 'image/png' }))
    return data
  }, { name, bytes: [...PNG] })

  for(const type of ['dragenter', 'dragover', 'drop']) {
    await composer(page).dispatchEvent(type, { dataTransfer })
  }

  await expect(page.locator('#composer-attachments [data-pending-attachment]')).toContainText(name)
  await expect(composer(page)).toHaveText('')
})
