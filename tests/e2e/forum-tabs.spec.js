const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'
const owner = { email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass' }

async function openForum(page, request, slug) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: 'ensure_channel', slug, name: 'Tabs', kind: 'forum' },
  })
  expect(response.ok()).toBeTruthy()
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ ...owner, next: `/?channel=${slug}` }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
  await expect(page.locator('#forum-tab')).toBeVisible()
}

async function createPost(page, title) {
  await page.locator('#new-forum-post').click()
  await page.locator('#forum-post-form input[name="post[title]"]').fill(title)
  await page.locator('#forum-post-form textarea[name="post[body]"]').fill(`body of ${title}`)
  await page.locator('#submit-forum-post').click()
  await expect(page.locator('[id^="thread-message-list-"]', { hasText: `body of ${title}` })).toBeVisible()
  await page.locator('[id^="close-thread-"]').click()
  await expect(page.locator('#forum-posts')).toBeVisible()
}

async function archivePost(page, title) {
  await page.locator('#forum-posts > li', { hasText: title }).locator('a').first().click()
  await page.locator('[id^="thread-actions-"]').first().click()
  await page.locator('[id^="toggle-archive-thread-"]').first().click()
  await page.locator('[id^="close-thread-"]').click()
  await expect(page.locator('#forum-posts')).toBeVisible()
}

test('the Active and Archived switch shows each post under one status only', async ({ page, request }) => {
  const stamp = Date.now()
  const kept = `Kept ${stamp}`
  const archived = `Archived ${stamp}`
  await openForum(page, request, `forum-tabs-${stamp}`)

  await createPost(page, kept)
  await createPost(page, archived)
  await archivePost(page, archived)

  const posts = page.locator('#forum-posts > li')
  await expect(posts.filter({ hasText: kept })).toHaveCount(1)
  await expect(posts.filter({ hasText: archived })).toHaveCount(0)

  await page.locator('#forum-tab-archived').click()
  await expect(page.locator('#forum-tab-archived')).toHaveAttribute('aria-pressed', 'true')
  await expect(posts.filter({ hasText: archived })).toHaveCount(1)
  await expect(posts.filter({ hasText: kept })).toHaveCount(0)

  await page.locator('#forum-tab-active').click()
  await expect(page.locator('#forum-tab-active')).toHaveAttribute('aria-pressed', 'true')
  await expect(posts.filter({ hasText: kept })).toHaveCount(1)
  await expect(posts.filter({ hasText: archived })).toHaveCount(0)
})

test('the forum toolbar fits the viewport without horizontal scrolling', async ({ page, request }) => {
  await openForum(page, request, `forum-tabs-layout-${Date.now()}`)

  const toolbar = ['forum-tab', 'forum-sort', 'forum-layout', 'new-forum-post']
  const { viewport, scrollWidth, clientWidth, boxes } = await page.evaluate((ids) => {
    const boxes = ids.map((id) => {
      const { left, right } = document.getElementById(id).getBoundingClientRect()
      return { id, left, right }
    })
    return {
      viewport: window.innerWidth,
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      boxes,
    }
  }, toolbar)

  expect(scrollWidth).toBeLessThanOrEqual(clientWidth)
  for (const box of boxes) {
    expect(box.left, box.id).toBeGreaterThanOrEqual(0)
    expect(box.right, box.id).toBeLessThanOrEqual(viewport)
  }
})
