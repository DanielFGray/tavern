const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

async function loginAs(page, payload, next = '/') {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ password: 'supersecurepass', next, ...payload }))
  await page.goto(url.toString())
}

const owner = { email: 'e2e@example.com', username: 'e2e_user' }

// Act only once the socket has connected: the connected mount reads the shared test database,
// which can take several seconds.
async function connected(page) {
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
}

test('an owner kicks with deletion scheduled, the member sees the date, and the owner cancels', async ({ page, browser, request }, testInfo) => {
  // A fresh member per run: the run in another project leaves its member kicked.
  const stamp = Date.now().toString(36)
  const email = `e2e-doomed-${stamp}@example.com`
  const username = `e2e_doomed_${stamp}`
  const { user: member } = await command(request, 'upsert_user', {
    email,
    username,
    display_name: 'Doomed Member',
  })

  await loginAs(page, owner)
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
  await page.goto('/settings?tab=members')
  await connected(page)

  await page.locator(`#open-member-actions-${member.id}`).click()
  page.once('dialog', (dialog) => dialog.accept())
  await page.locator(`#kick-schedule-deletion-${member.id}`).click()

  const entry = page.locator(`#scheduled-deletion-${member.id}`)
  await expect(entry).toContainText('Deletion scheduled for')
  await expect(page.locator(`#member-presence-${member.id}`)).toHaveCount(0)
  await entry.scrollIntoViewIfNeeded()
  await page.screenshot({ path: testInfo.outputPath('scheduled-deletions-panel.png'), fullPage: false })

  const memberContext = await browser.newContext()
  const memberPage = await memberContext.newPage()
  await loginAs(memberPage, { email, username })
  await expect(memberPage.locator('#deletion-scheduled')).toContainText('will be deleted on')
  await memberPage.screenshot({ path: testInfo.outputPath('removed-page-deletion-date.png') })
  await memberContext.close()

  page.once('dialog', (dialog) => dialog.accept())
  await page.locator(`#cancel-deletion-${member.id}`).click()
  await expect(entry).toHaveCount(0)
  await expect(page.locator('#scheduled-deletion-list-empty')).toBeVisible()
  await page.locator('#scheduled-deletions-panel').scrollIntoViewIfNeeded()
  await page.screenshot({ path: testInfo.outputPath('scheduled-deletion-canceled.png') })
})

test("a deleted author's messages show as Deleted user", async ({ page, request }, testInfo) => {
  const stamp = Date.now().toString(36)
  const gone = `e2e_gone_${stamp}`
  await command(request, 'upsert_user', {
    email: `e2e-gone-${stamp}@example.com`,
    username: gone,
    display_name: 'Gone Soon',
  })
  const { message } = await command(request, 'create_message', {
    channel_slug: 'general',
    username: gone,
    body: `These words outlive their author ${stamp}.`,
  })
  await command(request, 'delete_account', { username: gone })

  await loginAs(page, owner)
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()

  const row = page.locator(`#messages-${message.id}`)
  await expect(row).toContainText(`These words outlive their author ${stamp}.`)
  await expect(row).toContainText('Deleted user')
  await expect(row).not.toContainText('Gone Soon')
  await row.scrollIntoViewIfNeeded()
  await page.screenshot({ path: testInfo.outputPath('deleted-author-message.png') })
})
