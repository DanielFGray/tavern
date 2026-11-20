const { test, expect } = require('@playwright/test')

const { baseURL, command, login, unique } = require('./support')

// A direct link to an image file gets a card with the image the server fetched and stored, and
// markdown image syntax renders as a link. The browser loads images only from this origin, so
// the page makes no request to the image's host and the img-src policy reports no violation.
test('an image link shows the stored image card, and a markdown image is only a link', async ({ page, request }, testInfo) => {
  const suffix = unique(testInfo)
  const account = {
    email: `test_img_${suffix}@example.com`,
    username: `test_img_${suffix}`,
    password: 'supersecurepass',
  }
  const bareImage = `https://images.site.test/bare-${suffix}.png`
  const markdownImage = `https://images.site.test/md-${suffix}.png`

  await command(request, 'upsert_user', account)
  await command(request, 'stub_link_previews')

  const foreignRequests = []
  page.on('request', (sent) => {
    const url = new URL(sent.url())
    if(!['http:', 'https:'].includes(url.protocol)) return
    if(url.origin !== new URL(baseURL).origin) foreignRequests.push(sent.url())
  })
  await page.addInitScript(() => {
    window.__cspViolations = []
    document.addEventListener('securitypolicyviolation', (event) =>
      window.__cspViolations.push(`${event.violatedDirective} ${event.blockedURI}`),
    )
  })

  await login(page, { ...account, next: '/?channel=general' })

  await command(request, 'create_message', {
    channel_slug: 'general',
    username: account.username,
    body: `![a cat ${suffix}](${markdownImage}) and ${bareImage} https://youtu.be/dQw4w9WgXcQ`,
  })

  const message = page.locator(`#message-list [data-markdown-source*="${suffix}"]`).last()
  await expect(message.locator(`a[href="${markdownImage}"]`)).toHaveText(`a cat ${suffix}`)
  await expect(message.locator('img')).toHaveCount(0)

  const cards = page.locator('[id^="message-embeds-"] [data-kind="image"]')
  const bareCard = cards.filter({ has: page.locator(`a[href="${bareImage}"]`) })
  const markdownCard = cards.filter({ has: page.locator(`a[href="${markdownImage}"]`) })

  const embeds = page.locator('[id^="message-embeds-"]').filter({ has: page.locator(`a[href="${bareImage}"]`) })
  const thumbnail = embeds.locator('[data-kind="video"] img[src^="/uploads/embeds/"]')

  for(const image of [bareCard.locator('img'), markdownCard.locator('img'), thumbnail]) {
    await expect(image).toHaveAttribute('src', /^\/uploads\/embeds\//)
    await expect.poll(() => image.evaluate((img) => img.complete && img.naturalWidth)).toBe(1)
  }

  expect(await page.evaluate(() => window.__cspViolations)).toEqual([])
  expect(foreignRequests).toEqual([])

  // The author removes the embeds from an image card, which stays large enough to click.
  await bareCard.locator('[id^="remove-embed-"]').click()
  await expect(embeds).toHaveCount(0)

  // The policy is enforced: an image from another host is blocked and reported.
  await page.evaluate(() => { new Image().src = 'https://images.site.test/probe.png' })
  await expect.poll(() => page.evaluate(() => window.__cspViolations)).toEqual([
    'img-src https://images.site.test/probe.png',
  ])
})
