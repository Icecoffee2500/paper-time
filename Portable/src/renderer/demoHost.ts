export {}
/**
 * Before the website's demos load: which language they speak. `demos.js`
 * reads the document's `lang` once, as it starts (`const KO = …`).
 */
const asked = new URLSearchParams(location.search)
document.documentElement.lang = asked.get('lang') === 'en' ? 'en' : 'ko'
