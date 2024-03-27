--liquibase formatted sql

--changeset  BrandonStahl:f0412dc1-b0e4-45e4-9e90-28e189838459 stripComments:false runOnChange:true splitStatements:false

-- =============================================
--             :
--      Author : Brandon Stahl
--             :
--     Created : 2024-02-28
--             :
-- Description : This report sets and updates 2FA settings for email and phone types.
--             :
--             :
--       Usage : EXEC [Account].[P_UpsertUserTwoFASettings] 165227, 'Email', 'Test@Tcetra.com'
--             :
-- =============================================
CREATE OR ALTER PROCEDURE [Account].[P_UpsertUserTwoFASettings]
    (
        @UserId INT,
        @DestinationType VARCHAR(50),
        @Destination VARCHAR(150),
        @ParentAccountId INT
    )
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
    DECLARE
        @DestinationTypeId INT

    BEGIN TRY
        IF
            NOT EXISTS (
                SELECT 1
                FROM dbo.Users AS u
                WHERE
                    u.[User_ID] = @UserId
                    AND Account.FnIsChildDescendantOfParent(u.Account_ID, @ParentAccountId) = 1
            )
            BEGIN
                SELECT
                    @UserId AS UserId,
                    @DestinationType AS DestinationType,
                    @Destination AS Destination,
                    'User does not exist' AS [Message]
                RETURN;
            END;

        SET
            @DestinationTypeId =
            (
                SELECT
                    pd.ID
                FROM Account.tblPreferedDestination AS pd
                WHERE
                    pd.[Description] = ISNULL(@DestinationType, '')
                    AND (@DestinationType = 'Email' OR @DestinationType = 'Phone')
            );

        IF @DestinationTypeId = 0
            BEGIN
                SELECT
                    @UserId AS UserId,
                    @DestinationType AS DestinationType,
                    @Destination AS Destination,
                    'Destination type not Supported' AS [Message]
                RETURN;
            END;

        SET @Destination = TRIM(@Destination);
        IF @DestinationType = 'Phone'
            BEGIN
                SET @Destination = REPLACE(TRANSLATE(@Destination, '.+()- ,+', '########'), '#', '');
            END

        IF @DestinationType = 'Phone' AND (TRY_CONVERT(INT, @Destination) = 1 OR LEN(@Destination) <> 10)
            BEGIN
                SELECT
                    @UserId AS UserId,
                    @DestinationType AS DestinationType,
                    @Destination AS Destination,
                    'Invalid phone number' AS [Message]
                RETURN;
            END;

        IF @DestinationType = 'Email' AND @Destination NOT LIKE '%_@__%.__%'
            BEGIN
                SELECT
                    @UserId AS UserId,
                    @DestinationType AS DestinationType,
                    @Destination AS Destination,
                    'Invalid email' AS [Message]
                RETURN;
            END;

        UPDATE utfs
        SET
            utfs.Email =
            CASE
                WHEN @DestinationType = 'Email' THEN @Destination
                ELSE ''
            END,
            utfs.PhoneNumber =
            CASE
                WHEN @DestinationType = 'Phone' THEN @Destination
                ELSE ''
            END,
            utfs.PreferredDestination = @DestinationTypeId
        FROM Account.tblUserTwoFactorSettings AS utfs
        WHERE utfs.UserId = @UserId

        IF NOT EXISTS (SELECT 1 FROM Account.tblUserTwoFactorSettings AS utfs WHERE utfs.UserId = @UserId)
            BEGIN
                INSERT Account.tblUserTwoFactorSettings
                (
                    UserId,
                    Email,
                    PhoneNumber,
                    PreferredDestination,
                    AuthenticatorId
                )
                VALUES
                (
                    @UserId,
                    CASE
                        WHEN @DestinationType = 'Email' THEN @Destination
                        ELSE ''
                    END,
                    CASE
                        WHEN @DestinationType = 'Phone' THEN @Destination
                        ELSE ''
                    END,
                    @DestinationTypeId,
                    ''
                );
            END;

        SELECT
            @UserId AS UserId,
            @DestinationType AS DestinationType,
            @Destination AS Destination,
            'Success' AS [Message]
    END TRY
    BEGIN CATCH
        SELECT
            @UserId AS UserId,
            @DestinationType AS DestinationType,
            @Destination AS Destination,
            'An Error has occurred' AS [Message]
        RETURN;
    END CATCH;
END;
