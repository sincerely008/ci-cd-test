package com.example.cicdtest.note;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.time.Instant;

@RestController
@RequestMapping("/api/notes")
public class NoteController {

    private final NoteRepository noteRepository;

    public NoteController(NoteRepository noteRepository) {
        this.noteRepository = noteRepository;
    }

    @PostMapping
    public ResponseEntity<NoteResponse> create(@RequestBody CreateNoteRequest request) {
        if (request == null || request.content() == null || request.content().isBlank() || request.content().length() > 500) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "content must contain 1 to 500 characters");
        }

        Note note = noteRepository.save(new Note(request.content().trim()));
        return ResponseEntity.status(HttpStatus.CREATED).body(NoteResponse.from(note));
    }

    @GetMapping("/{id}")
    public NoteResponse findById(@PathVariable Long id) {
        Note note = noteRepository.findById(id)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "note not found"));
        return NoteResponse.from(note);
    }

    public record CreateNoteRequest(String content) {
    }

    public record NoteResponse(Long id, String content, Instant createdAt) {
        private static NoteResponse from(Note note) {
            return new NoteResponse(note.getId(), note.getContent(), note.getCreatedAt());
        }
    }
}
