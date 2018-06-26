module QA
  feature 'fork project', :core do
    scenario 'user submits merge request from a forked project' do
      Runtime::Browser.visit(:gitlab, Page::Main::Login)
      Page::Main::Login.act { sign_in_using_credentials }

      merge_request = Factory::Resource::MergeRequestFromFork.fabricate!

      Page::Menu::Main.act { sign_out }
      Page::Main::Login.act do
        switch_to_sign_in_tab
        sign_in_using_credentials
      end

      merge_request.visit!
      Page::MergeRequest::Show.act { merge! }

      expect(page).to have_content('The changes were merged')
    end
  end
end
