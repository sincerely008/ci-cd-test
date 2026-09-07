package com.example.cicdtest.note;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.httpBasic;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest(properties = {
        "spring.datasource.url=jdbc:h2:mem:notes-test;DB_CLOSE_DELAY=-1",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.security.user.name=test-user",
        "spring.security.user.password=test-password"
})
@AutoConfigureMockMvc
class NoteControllerIntegrationTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void createsAndReadsAnAuthenticatedNote() throws Exception {
        MvcResult result = mockMvc.perform(post("/api/notes")
                        .with(httpBasic("test-user", "test-password"))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"content\":\"persist this note\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").isNumber())
                .andExpect(jsonPath("$.content").value("persist this note"))
                .andReturn();

        Matcher idMatcher = Pattern.compile("\\\"id\\\":(\\d+)")
                .matcher(result.getResponse().getContentAsString());
        assertTrue(idMatcher.find());
        long id = Long.parseLong(idMatcher.group(1));

        mockMvc.perform(get("/api/notes/{id}", id)
                        .with(httpBasic("test-user", "test-password")))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(id))
                .andExpect(jsonPath("$.content").value("persist this note"));
    }

    @Test
    void rejectsBlankNoteContent() throws Exception {
        mockMvc.perform(post("/api/notes")
                        .with(httpBasic("test-user", "test-password"))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"content\":\"   \"}"))
                .andExpect(status().isBadRequest());
    }
}
