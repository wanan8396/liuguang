package cn.liuguang.engine

import org.junit.Assert.*
import org.junit.Test

class JpjSourceCompatTest {
    @Test fun forbiddenHtmlIsNotAnAvailableCatalog() {
        assertFalse(JpjSourceCompat.isCatalog(403, "<html><h1>403 Forbidden</h1></html>"))
        assertFalse(JpjSourceCompat.isCatalog(200, "<html>temporary failure</html>"))
        assertFalse(JpjSourceCompat.isCatalog(403, "{\"data\":[]}"))
        assertFalse(JpjSourceCompat.isCatalog(200, "{\"data\":\"unavailable\"}"))
        assertTrue(JpjSourceCompat.isCatalog(200, "{\"code\":1,\"data\":[{\"id\":187}]}"))
    }

    @Test fun txtMirrorsHandleQuotesAndRejectNonDomainEntries() {
        val body = """{"Answer":[{"type":16,"data":"\"a.example,b.example,a.example\""},{"type":16,"data":"\\\"c.example\\\",https://wrong.example,bad.example/path,x.example:80,-bad.example"},{"type":1,"data":"127.0.0.1"}]}"""
        assertEquals(listOf("a.example", "b.example", "c.example"), JpjSourceCompat.domains(body))
        assertTrue(JpjSourceCompat.domains("<html>error</html>").isEmpty())
        assertTrue(JpjSourceCompat.domains("{\"Status\":3}").isEmpty())
    }
}
