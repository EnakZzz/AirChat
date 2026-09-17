package com.airchat.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File

/**
 * Loads the cross-platform golden vectors from `<repo>/testdata`.
 *
 * The directory is injected by the Gradle test task (`airchat.testdata.dir`); the same JSON
 * files are consumed by the iOS XCTest target, which is what keeps the two ports byte-exact.
 */
object TestVectors {
    private val directory: File by lazy {
        val configured = System.getProperty("airchat.testdata.dir")
            ?: error("airchat.testdata.dir system property is not set")
        File(configured).also { require(it.isDirectory) { "not a directory: $it" } }
    }

    fun load(fileName: String): JsonObject {
        val file = File(directory, fileName)
        require(file.isFile) { "missing test vector file: $file" }
        return Json.parseToJsonElement(file.readText(Charsets.UTF_8)).jsonObject
    }

    fun hex(element: JsonElement): ByteArray =
        ByteOps.fromHex(element.jsonPrimitive.content)

    fun hexOrNull(element: JsonElement?): ByteArray? = element?.let { hex(it) }

    fun int(element: JsonElement): Int = element.jsonPrimitive.content.toInt()
}
