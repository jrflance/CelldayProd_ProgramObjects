--liquibase formatted sql

--changeset BrandonStahl:e81736ed2b5047bab51add90b798f5e6c44d77838916531ef96726 stripComments:false runOnChange:true splitStatements:false

/*
EXEC Tracfone.P_MailDealerApprovedSignup @FileId = 2769, @DebugEmail='chuge@tcetra.com'
*/
CREATE OR ALTER PROCEDURE [Tracfone].[P_MailDealerApprovedSignup]
    (
        @FileId INT = 2769,
        @DebugEmail VARCHAR(64) = NULL
    )
AS

DECLARE @tableHTML NVARCHAR(MAX)
DECLARE @Subject NVARCHAR(64) = 'Registered Accounts'
DECLARE @ParentId INT, @Email VARCHAR(512)
SELECT
    a1.Account_Id AS MaId,
    REPLACE(ISNULL(c1.Email, ''), ',', ';') + ';Sales@tcetra.com' AS ParEmail,
    a.Account_ID,
    a.Account_Name,
    c.Email
INTO #TmpList
FROM tracfone.tblDealerApprovedSignUp AS dasu
JOIN dbo.Account AS a ON dasu.NewAccountId = a.Account_ID
LEFT JOIN Customers AS c ON c.Customer_ID = a.Customer_ID
JOIN dbo.Account AS a1 ON a1.Account_ID = dbo.fn_GetTopParent_NotTcetra_h(a.hierarchy)
LEFT JOIN Customers AS c1 ON c1.Customer_ID = a1.Customer_ID
WHERE dasu.fileid = @FileId AND dasu.NewAccountId > 0

IF @DebugEmail IS NOT NULL
    UPDATE #TmpList SET ParEmail = @DebugEmail

DECLARE EmailParents CURSOR
FOR SELECT DISTINCT MaId, ParEmail FROM #TmpList
OPEN EmailParents
FETCH NEXT FROM EmailParents INTO @ParentID, @Email
WHILE @@FETCH_STATUS = 0
    BEGIN
        SET
            @tableHTML =
            N'<Div style="font-weight: bold;font-size: medium">
	        </Div>'

        SET
            @tableHTML =
            @tableHTML +
            N'<Div font-size: medium">
		    Dear Master Agent ' + CAST(@ParentID AS VARCHAR(30)) + ',	<BR><BR>
		    The below accounts were recently created under your Vidapay MA account. These locations signed up using the new account registration process. Please review, gather paperwork, check limits and account status, and notify dealer.
		    <BR><BR>
		    </Div>'

        -- noqa: disable=all
        SET
            @tableHTML = @tableHTML +
            N'<table border="1">' +
            N'<tr style="background-color: #FFC;font-weight: bold;font-size: medium;">' +
            N'	<td>Account ID</td>' +
            N'	<td>Account Name</td>' +
            N'	<td>Email</td>' +
            N'</tr>' +
            CAST(
                (
                    SELECT
					td = CAST(a.Account_ID AS VARCHAR(40)), '',
					td = CAST(a.Account_Name AS VARCHAR(128)), '',
					td = CAST(a.Email AS VARCHAR(128)), ''
					FROM #TmpList AS a
                    WHERE a.MaId = @parentID
                    ORDER BY a.Account_ID
                    FOR XML PATH ('tr_row'), TYPE
                ) AS NVARCHAR(MAX)
            ) +
            N'</table>';
        -- noqa: enable=all

        SET @tableHTML = REPLACE(@tableHTML, '<tr_row>', '<tr style="font-weight: normal;font-size: medium;">')
        SET @tableHTML = REPLACE(@tableHTML, '</tr_row>', '</tr>')
        SET @tableHTML = REPLACE(@tableHTML, '&lt;br&gt;', '<br>')

        -- V1
        BEGIN TRY
            EXECUTE msdb.dbo.sp_send_dbmail
                @profile_name = 'CellDayMail',
                @recipients = @Email,
                @subject = @Subject,
                @body = @tableHTML,
                @body_format = 'HTML'
        END TRY
        BEGIN CATCH
            CLOSE EmailParents
            DEALLOCATE EmailParents
        END CATCH

        FETCH NEXT FROM EmailParents INTO @ParentID, @Email
    END
CLOSE EmailParents
DEALLOCATE EmailParents
