package cn.liuguang.engine

import java.io.InputStream
import java.io.ByteArrayOutputStream

/** Avoid InputStream.readNBytes, unavailable on older Android ART versions. */
object BoundedIo {
    @JvmStatic fun read(input: InputStream,limit: Int): ByteArray {
        require(limit>=0)
        val out=ByteArrayOutputStream(minOf(limit,16384)); val buffer=ByteArray(16384)
        while(out.size()<limit) {
            if(Thread.currentThread().isInterrupted) throw java.io.InterruptedIOException("Read cancelled")
            val size=input.read(buffer,0,minOf(buffer.size,limit-out.size()))
            if(size<0) break
            if(size>0) out.write(buffer,0,size)
        }
        return out.toByteArray()
    }
}
